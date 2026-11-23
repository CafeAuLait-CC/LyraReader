use lyra_reader_ai::chat::build_reading_task;
use lyra_reader_ai::openai::{TokenUsage, response_usage};
use lyra_reader_ai::{
    Action, ChatSettings, ConversationTurn, DocumentChatRequest, DocumentKnowledgeInput, PageText,
    PlanRequest, build_document_chat_plan, build_document_knowledge_plan,
};

fn request(text: &str) -> PlanRequest {
    PlanRequest {
        action: Action::SummarizeDocument,
        document_title: "Synthetic shared reading".into(),
        page_count: 1,
        current_page: 0,
        selection: None,
        question: None,
        language: None,
        pages: vec![PageText {
            page: 0,
            text: text.into(),
            chars: vec![],
        }],
        settings: ChatSettings::default(),
        document_knowledge: None,
    }
}
fn chat(input: PlanRequest, question: &str) -> DocumentChatRequest {
    DocumentChatRequest {
        document_title: input.document_title,
        page_count: input.page_count,
        current_page: 0,
        pages: input.pages,
        question: question.into(),
        settings: input.settings,
        history: vec![],
        document_knowledge: Some(DocumentKnowledgeInput {
            text: "Generated overview that should not duplicate complete originals".into(),
            pages: vec![1],
        }),
    }
}

#[test]
fn prereading_summary_and_chat_reuse_the_exact_original_prefix() {
    let input = request(
        "A synthetic research purpose and its evidence.\n\nA second natural paragraph with an equation x = 2.",
    );
    let prior = build_document_knowledge_plan(input.clone()).unwrap();
    let summary = build_reading_task(input.clone(), "summary", "Standard").unwrap();
    let mut selected = input.clone();
    selected.selection = Some(lyra_reader_ai::SelectionRange {
        page: 0,
        start: 0,
        end: 3,
    });
    let from_selection = build_document_knowledge_plan(selected).unwrap();
    assert_eq!(
        from_selection.chat_completions_body(&from_selection.parts[0]),
        summary.chat_completions_body(&summary.parts[0]),
        "a selection cannot narrow a full preread"
    );
    assert_eq!(
        prior.chat_completions_body(&prior.parts[0]),
        summary.chat_completions_body(&summary.parts[0])
    );
    let answer = build_document_chat_plan(chat(input, "这篇文章的研究目的是什么？")).unwrap();
    assert_eq!(
        answer.parts[0].system_prompt,
        summary.parts[0].system_prompt
    );
    let end = summary.parts[0]
        .user_prompt
        .find("[End document original sources]\n\n")
        .unwrap()
        + "[End document original sources]\n\n".len();
    assert!(
        answer.parts[0]
            .user_prompt
            .starts_with(&summary.parts[0].user_prompt[..end])
    );
    assert!(!answer.parts[0].user_prompt.contains("Generated overview"));
    assert_eq!(answer.source_pages, vec![1]);
    let again = build_document_chat_plan(chat(request("A synthetic research purpose and its evidence.\n\nA second natural paragraph with an equation x = 2."), "Explain the equation.")).unwrap();
    assert_eq!(
        &again.parts[0].user_prompt[..end],
        &answer.parts[0].user_prompt[..end]
    );
}

#[test]
fn a_long_document_reads_the_requested_chapter_and_resolves_followups() {
    let source = format!(
        "1. Introduction\n{}\n3. Method\n{}\n2D pose is data, not a section heading.\n3.1 Ablation\nA synthetic ablation detail belongs to the method.\n4. Results\nUnrelated result must not enter this chapter context.",
        "Synthetic opening context for a long document. ".repeat(400),
        "Synthetic method evidence with an actual formula x = 2. ".repeat(25)
    );
    let first = build_document_chat_plan(chat(request(&source), "请解释第3节的方法。")).unwrap();
    let prompt = &first.parts[0].user_prompt;
    assert!(prompt.contains("actual formula x = 2"));
    assert!(prompt.contains("synthetic ablation detail"));
    assert!(!prompt.contains("Unrelated result must not enter"));
    assert!(prompt.contains("next detected sibling heading"));
    let mut follow = chat(request(&source), "这里为什么需要这个公式？");
    follow.history.push(ConversationTurn {
        question: "Explain section 3".into(),
        answer: "A synthetic prior answer.".into(),
    });
    let follow = build_document_chat_plan(follow).unwrap();
    assert!(follow.parts[0].user_prompt.contains("actual formula x = 2"));
    assert!(
        !follow.parts[0]
            .user_prompt
            .contains("Unrelated result must not enter")
    );
    let marker = "[End chapter sources]\n";
    let end = first.parts[0].user_prompt.find(marker).unwrap() + marker.len();
    assert!(
        follow.parts[0]
            .user_prompt
            .starts_with(&first.parts[0].user_prompt[..end]),
        "repeated chapter reads keep their source prefix before changing history"
    );
}

#[test]
fn oversized_chapter_has_a_bounded_and_honest_source_scope() {
    let input = request(&format!(
        "3. Method\n{}\n4. Results\nFinal result.",
        "Synthetic source evidence about the method.\n".repeat(800)
    ));
    let plan = build_document_chat_plan(chat(input, "Read section 3 in detail")).unwrap();
    assert!(plan.parts[0].page_characters < 13_000);
    assert!(
        plan.parts[0]
            .user_prompt
            .contains("partial chapter coverage")
    );
    assert!(!plan.parts[0].user_prompt.contains("Final result."));
}

#[test]
fn compact_understanding_keeps_the_end_and_usage_distinguishes_unknown_from_hits() {
    let text = format!(
        "# Overview\n{}\n## Method\n{}\n## Limitations\nThe synthetic experiment excludes a control.",
        "opening ".repeat(2000),
        "method ".repeat(2000)
    );
    let context = lyra_reader_ai::understanding::context(&text);
    assert!(context.chars().count() <= 6000);
    assert!(context.contains("excludes a control"));
    let first = response_usage(&serde_json::json!({"usage":{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110,"prompt_tokens_details":{"cached_tokens":80}}})).unwrap();
    let second = response_usage(&serde_json::json!({"usage":{"input_tokens":50,"output_tokens":5,"total_tokens":55,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":2}}})).unwrap();
    let total = first.merge(second);
    assert_eq!(total.cached_tokens, Some(80));
    assert_eq!(total.prompt_tokens, Some(150));
    assert_eq!(total.total_tokens, Some(165));
    assert_eq!(second.cached_tokens, Some(0));
    assert_eq!(second.reasoning_tokens, Some(2));
    let unknown = response_usage(&serde_json::json!({"usage":{"input_tokens":10}})).unwrap();
    assert_eq!(unknown.cached_tokens, None);
    assert_eq!(response_usage(&serde_json::json!({"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":50}}})).unwrap().cached_tokens, None);
    assert_eq!(TokenUsage::default().cached_tokens, None);
}
