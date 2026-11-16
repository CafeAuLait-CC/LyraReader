use lyra_reader_ai::chat::{ChatTransport, PageChar, build_reading_task, locate_reading_source};
use lyra_reader_ai::workspace::translation_blocks;
use lyra_reader_ai::{
    Action, ChatSettings, DocumentKnowledgeInput, PageText, PlanRequest, SelectionRange,
};

fn request(texts: &[&str]) -> PlanRequest {
    PlanRequest {
        action: Action::SummarizeDocument,
        document_title: "Synthetic reading fixture".into(),
        page_count: texts.len() as u32,
        current_page: 0,
        selection: None,
        question: None,
        language: Some("Simplified Chinese".into()),
        pages: texts
            .iter()
            .enumerate()
            .map(|(i, text)| PageText {
                page: i as u32,
                text: text.to_string(),
                chars: vec![],
            })
            .collect(),
        settings: ChatSettings::default(),
        document_knowledge: None,
    }
}

#[test]
fn short_summary_is_one_task_with_actual_sources_and_detail() {
    let plan = build_reading_task(
        request(&["First paragraph.", "Second paragraph."]),
        "summary",
        "Detailed",
    )
    .unwrap();
    assert_eq!(plan.parts.len(), 1);
    assert_eq!(plan.source_pages, vec![1, 2]);
    assert!(
        plan.parts[0]
            .system_prompt
            .contains("evidence and limitations")
    );
    assert!(plan.parts[0].system_prompt.contains("Simplified Chinese"));
    assert_eq!(
        plan.chat_completions_body(&plan.parts[0]),
        include_str!("fixtures/reading-summary-chat.golden.json")
    );
    assert_eq!(
        plan.responses_body(&plan.parts[0]),
        include_str!("fixtures/reading-summary-responses.golden.json")
    );
    for transport in [ChatTransport::Responses, ChatTransport::ChatCompletions] {
        let rendered = plan.clone().rendered(transport);
        for part in &rendered.parts {
            assert_eq!(
                part.wire_body.as_ref().unwrap(),
                &plan.render_body(part, transport)
            );
        }
    }
}

#[test]
fn selection_keeps_raw_character_offsets_without_surroundings() {
    let mut input = request(&["prefix\r\n  e\u{301} 中 suffix"]);
    input.selection = Some(SelectionRange {
        page: 0,
        start: 8,
        end: 14,
    });
    input.document_knowledge = Some(DocumentKnowledgeInput {
        text: "Unrelated private document context".into(),
        pages: vec![1],
    });
    let plan = build_reading_task(input, "summary", "Brief").unwrap();
    assert!(!plan.parts[0].user_prompt.contains("prefix"));
    assert!(!plan.parts[0].user_prompt.contains("suffix"));
    assert!(!plan.parts[0].user_prompt.contains("Unrelated private"));
    assert_eq!(
        plan.parts[0].page_characters,
        plan.sources[0].snippet.chars().count() as u64
    );
}

#[test]
fn translation_splits_for_output_capacity_without_losing_unicode_or_paragraphs() {
    let text =
        "A natural paragraph with consistent terminology.\n\n".repeat(50) + &"中文🔬".repeat(450);
    let mut input = request(&[&text]);
    input.document_knowledge = Some(DocumentKnowledgeInput {
        text: "Generated document summary must not be translated".into(),
        pages: vec![1],
    });
    let plan = build_reading_task(input, "translation", "Standard").unwrap();
    assert!(plan.parts.len() > 1);
    assert!(
        plan.parts[1]
            .user_prompt
            .contains("Terminology context from this task's source")
    );
    assert!(
        plan.parts
            .iter()
            .all(|part| !part.user_prompt.contains("Generated document summary"))
    );
    assert_eq!(plan.action, Action::TranslateSelection);
    let rebuilt = plan
        .sources
        .iter()
        .map(|s| s.snippet.as_str())
        .collect::<String>();
    assert_eq!(rebuilt.replace('\n', ""), text.replace('\n', ""));
    let originals: Vec<_> = plan.sources.iter().map(|s| s.snippet.clone()).collect();
    let pages: Vec<_> = plan.sources.iter().map(|s| s.page).collect();
    let response = (0..originals.len())
        .map(|i| format!("<!--lyra:{i}-->Translated {i}\n"))
        .collect::<String>();
    let blocks = translation_blocks(&originals, &pages, &response).unwrap();
    assert_eq!(blocks.len(), originals.len());
    assert!(blocks.iter().all(|b| !b.translation.is_empty()));
    assert!(translation_blocks(&originals, &pages, "<!--lyra:0-->one<!--lyra:0-->two").is_err());
    assert!(translation_blocks(&originals, &pages, "<!--lyra:999999-->bad").is_err());
}

#[test]
fn missing_text_and_invalid_settings_do_not_produce_a_sendable_plan() {
    assert!(build_reading_task(request(&[""]), "translation", "Standard").is_err());
    assert!(build_reading_task(request(&["source"]), "summary", "Unknown").is_err());
    let mut missing = request(&["source"]);
    missing.page_count = 2;
    assert!(build_reading_task(missing, "summary", "Standard").is_err());
}

#[test]
fn normalized_reading_sources_locate_raw_crlf_geometry() {
    let raw = "First line.  \r\nSecond line.";
    let page = PageText {
        page: 0,
        text: raw.into(),
        chars: raw
            .chars()
            .enumerate()
            .map(|(i, c)| PageChar {
                unicode: c as u32,
                x_pt: i as f64,
                y_pt: if i < 15 { 0.0 } else { 10.0 },
                width_pt: 1.0,
                height_pt: 2.0,
            })
            .collect(),
    };
    let rects = locate_reading_source(&page, "First line.\nSecond line.").unwrap();
    assert_eq!(rects.len(), 2);
    assert_eq!(rects[0].y_pt, 0.0);
    assert_eq!(rects[1].y_pt, 10.0);
    assert!(
        locate_reading_source(&page, "Absent source")
            .unwrap()
            .is_empty()
    );
}
