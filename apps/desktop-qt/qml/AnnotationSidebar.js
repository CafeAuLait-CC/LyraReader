.pragma library

// Compose native rows from Rust's clusters and the existing reply-thread projection.
// Sentence boundaries, source ranges and clustering never run in this module.
function rows(threads,frames,keys) {
    const roots=new Map(),replies=new Map(),clusters=new Map();
    for(let i=0;i<threads.length;++i) {
        const row=threads[i];
        if(row.depth===0)roots.set(row.annotation.id,row);
        else {if(!replies.has(row.rootID))replies.set(row.rootID,[]);replies.get(row.rootID).push({index:i,row:row});}
    }
    for(const page of Object.keys(frames)) {
        const frame=frames[page];
        if(!keys[page] || frame.input_key!==keys[page])continue;
        for(const group of frame.groups || []) {
            if(!group.members.length || !group.members.every(function(m){return roots.has(m.id) && String(roots.get(m.id).annotation.page)===page && !roots.get(m.id).annotation.is_reply;}))continue;
            const marks=group.members.map(function(m,index){return {source:roots.get(m.id),start:m.start,end:m.end,order:index};});
            marks.sort(function(a,b){return Number(!a.source.annotation.foreign)-Number(!b.source.annotation.foreign) || a.order-b.order;});
            const projected=Object.assign({},group,{marks:marks});
            for(const member of group.members)clusters.set(member.id,projected);
        }
    }
    const result=[],emitted=new Set();
    const ordered=threads.map(function(row,index){return {row:row,index:index};}).filter(function(value){return value.row.depth===0;});
    ordered.sort(function(a,b){return a.row.sectionPage-b.row.sectionPage || Number(!a.row.annotation.foreign)-Number(!b.row.annotation.foreign) || a.index-b.index;});
    for(const value of ordered) {
        const row=value.row;
        const group=clusters.get(row.annotation.id);
        const identity=group ? "passage:"+group.id : "annotation:"+row.annotation.id;
        if(emitted.has(identity))continue;emitted.add(identity);
        const ids=group ? group.marks.map(function(m){return m.source.annotation.id;}) : [row.annotation.id];
        result.push(Object.assign({},row,{passage:group || null,sourceIDs:ids}));
        let children=[];
        for(const id of ids)children=children.concat(replies.get(id) || []);
        for(const child of children)result.push(Object.assign({},child.row,{passage:null,sourceIDs:[child.row.annotation.id]}));
    }
    return result;
}
