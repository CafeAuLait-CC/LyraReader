.pragma library

// All rectangles are canvas logical pixels. PDF/paper transforms stay with PaperRegion.
function valid(rect) {
    return rect && [rect.x,rect.y,rect.width,rect.height].every(Number.isFinite)
        && rect.width>0 && rect.height>0;
}
function intersects(a,b) {
    return a.x<b.x+b.width && b.x<a.x+a.width && a.y<b.y+b.height && b.y<a.y+a.height;
}
function expanded(rect,inset) {
    return {x:rect.x-inset,y:rect.y-inset,width:rect.width+inset*2,height:rect.height+inset*2};
}
function place(pieces,viewport,size,tearGap) {
    if(!valid(viewport) || !size || !Number.isFinite(size.width) || !Number.isFinite(size.height)
            || size.width<=0 || size.height<=0)return null;
    const visible=[];
    let anchor=null,area=0,anchorIndex=-1;
    for(let i=0;i<pieces.length;++i) {
        const piece=pieces[i];
        if(!valid(piece))continue;
        const current=Math.max(0,Math.min(piece.x+piece.width,viewport.x+viewport.width)-Math.max(piece.x,viewport.x))
            *Math.max(0,Math.min(piece.y+piece.height,viewport.y+viewport.height)-Math.max(piece.y,viewport.y));
        if(current<=0)continue;
        visible.push(expanded(piece,1));
        if(!anchor || current>area+0.5 || (Math.abs(current-area)<=0.5 && piece.y<anchor.y)) {
            anchor=piece;area=current;anchorIndex=i;
        }
    }
    if(!anchor)return null;
    const canvas=expanded(viewport,-4);
    if(!valid(canvas))return null;
    const gap=valid(tearGap) ? expanded(tearGap,2) : null;
    function clamp(x,y) {
        return {x:Math.min(Math.max(x,canvas.x),Math.max(canvas.x,canvas.x+canvas.width-size.width)),
            y:Math.min(Math.max(y,canvas.y),Math.max(canvas.y,canvas.y+canvas.height-size.height)),
            width:size.width,height:size.height};
    }
    const candidates=[
        ["right",anchor.x+anchor.width+4,anchor.y],
        ["above",anchor.x+anchor.width-size.width,anchor.y-size.height-4],
        ["below",anchor.x+anchor.width-size.width,anchor.y+anchor.height+4],
        ["left",anchor.x-size.width-4,anchor.y]
    ];
    for(const candidate of candidates) {
        const rect=clamp(candidate[1],candidate[2]);
        if(rect.x+rect.width>canvas.x+canvas.width || rect.y+rect.height>canvas.y+canvas.height)continue;
        if(visible.some(function(piece){return intersects(piece,rect);}) || (gap && intersects(gap,rect)))continue;
        rect.inside=false;rect.position=candidate[0];rect.anchorIndex=anchorIndex;return rect;
    }
    const rect=clamp(anchor.x+anchor.width-size.width-2,anchor.y+2);
    rect.inside=true;rect.position="inside";rect.anchorIndex=anchorIndex;return rect;
}
