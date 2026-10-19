.pragma library

function rows(pages, gap) {
    const result = []
    for (const page of pages) {
        let row = result[result.length - 1]
        if (!row || Math.abs(row.top - page.top) > 0.01) {
            row = {top: page.top, bottom: page.top + page.height, pages: []}
            result.push(row)
        }
        row.pages.push(page)
        row.bottom = Math.max(row.bottom, page.top + page.height)
    }
    for (let i = 0; i < result.length; ++i)
        result[i].height = result[i].bottom - result[i].top + (i + 1 < result.length ? gap : 0)
    return result
}
function nearestCharacter(chars, x, y) {
    let best = -1, distance = Infinity
    for (let i = 0; i < chars.length; ++i) {
        const c = chars[i]
        if (!(c.width_pt > 0 && c.height_pt > 0)) continue
        const dx = Math.max(c.x_pt - x, 0, x - c.x_pt - c.width_pt)
        const dy = Math.max(c.y_pt - y, 0, y - c.y_pt - c.height_pt)
        const d = dx * dx + dy * dy * 16
        if (d < distance) { distance = d; best = i }
    }
    return best
}
function quads(chars, start, end) {
    const result = []
    for (let i = Math.max(0, Math.min(start, end)); i <= Math.max(start, end) && i < chars.length; ++i) {
        const c = chars[i]
        if (!(c.width_pt > 0 && c.height_pt > 0)) continue
        let q = result[result.length - 1]
        if (q && Math.abs(q.y - c.y_pt) < Math.min(q.height, c.height_pt) * 0.5 && Math.abs(q.x + q.width - c.x_pt) < Math.max(8, c.height_pt)) {
            const right = Math.max(q.x + q.width, c.x_pt + c.width_pt)
            q.x = Math.min(q.x, c.x_pt)
            q.width = right - q.x
            q.height = Math.max(q.height, c.height_pt)
        } else result.push({x:c.x_pt,y:c.y_pt,width:c.width_pt,height:c.height_pt})
    }
    return result
}
function selectedText(chars, start, end) {
    let result = ""
    for (let i = Math.max(0, Math.min(start,end)); i <= Math.max(start,end) && i < chars.length; ++i) {
        const u = chars[i].unicode
        if (u > 0 && u <= 0x10ffff) result += String.fromCodePoint(u)
    }
    return result
}
function contains(rect, x, y) {
    return x >= rect.x_pt && y >= rect.y_pt && x <= rect.x_pt + rect.width_pt && y <= rect.y_pt + rect.height_pt
}
function hex(n) { return Math.round(Math.max(0,Math.min(255,n))).toString(16).padStart(2,"0") }
function normalized(a, foreign) {
    const b=Object.assign({},a)
    b.foreign=foreign
    if (foreign) {
        b.kind=a.kind==="text" ? "stickyNote" : a.kind==="freeText" ? "textBox" : a.kind
        b.rect={x:a.x_pt,y:a.y_pt,width:a.width_pt,height:a.height_pt}
        b.paths=(a.ink_paths || []).map(function(path){return path.map(function(p){return {x:p.x_pt,y:p.y_pt}})})
        b.lineStart=a.line_start ? {x:a.line_start.x_pt,y:a.line_start.y_pt} : null
        b.lineEnd=a.line_end ? {x:a.line_end.x_pt,y:a.line_end.y_pt} : null
        b.strokeWidth=a.border_width_pt || 2
        b.fontSize=a.font_size_pt || 14
        b.note=a.contents || ""
        const c=a.color || {red:232,green:188,blue:85}
        b.color="#"+hex(c.red)+hex(c.green)+hex(c.blue)+hex((a.opacity===null || a.opacity===undefined ? 1 : a.opacity)*255)
        b.visible=a.visible && a.drawing==="drawn"
    } else b.visible=true
    b.quads=(a.quads || []).map(function(q){return {x:q.x_pt===undefined ? q.x : q.x_pt,y:q.y_pt===undefined ? q.y : q.y_pt,width:q.width_pt===undefined ? q.width : q.width_pt,height:q.height_pt===undefined ? q.height : q.height_pt}})
    if (!b.rect || !(b.rect.width>0 && b.rect.height>0)) {
        const points=[]
        for (const q of b.quads) points.push({x:q.x,y:q.y},{x:q.x+q.width,y:q.y+q.height})
        for (const path of b.paths || []) for (const p of path) points.push(p)
        if (b.lineStart && b.lineEnd) points.push(b.lineStart,b.lineEnd)
        if (points.length) {
            const left=Math.min.apply(null,points.map(function(p){return p.x})),top=Math.min.apply(null,points.map(function(p){return p.y}))
            b.rect={x:left,y:top,width:Math.max(.1,Math.max.apply(null,points.map(function(p){return p.x}))-left),height:Math.max(.1,Math.max.apply(null,points.map(function(p){return p.y}))-top)}
        }
    }
    return b
}
function color(a) {
    const c=a.color || "#E8BC5552"
    return Qt.rgba(parseInt(c.slice(1,3),16)/255,parseInt(c.slice(3,5),16)/255,parseInt(c.slice(5,7),16)/255,c.length===9 ? parseInt(c.slice(7,9),16)/255 : 1)
}
function segmentDistance(x,y,a,b) {
    const dx=b.x-a.x,dy=b.y-a.y,l=dx*dx+dy*dy
    const t=l ? Math.max(0,Math.min(1,((x-a.x)*dx+(y-a.y)*dy)/l)) : 0
    return Math.hypot(x-a.x-t*dx,y-a.y-t*dy)
}
function hit(a,x,y,reach) {
    if (!a.visible) return false
    const distance=reach || 4
    if (a.kind==="ink") {
        for (const path of a.paths || []) for (let i=1;i<path.length;++i)
            if (segmentDistance(x,y,path[i-1],path[i])<=distance+(a.strokeWidth || 2)/2) return true
        return false
    }
    if (a.kind==="line" || a.kind==="arrow") return a.lineStart && a.lineEnd && segmentDistance(x,y,a.lineStart,a.lineEnd)<=distance+(a.strokeWidth || 2)/2
    if (a.kind==="highlight" || a.kind==="underline" || a.kind==="strikeout")
        return a.quads.some(function(q){return x>=q.x && y>=q.y && x<=q.x+q.width && y<=q.y+q.height})
    const r=a.rect
    if (!r) return false
    if (a.kind==="square") return x>=r.x-distance && y>=r.y-distance && x<=r.x+r.width+distance && y<=r.y+r.height+distance && (Math.abs(x-r.x)<=distance || Math.abs(x-r.x-r.width)<=distance || Math.abs(y-r.y)<=distance || Math.abs(y-r.y-r.height)<=distance)
    if (a.kind==="circle") {const d=Math.hypot((x-r.x-r.width/2)/(r.width/2),(y-r.y-r.height/2)/(r.height/2));return Math.abs(d-1)<=distance/Math.max(1,Math.min(r.width,r.height)/2)}
    return x>=r.x && y>=r.y && x<=r.x+r.width && y<=r.y+r.height
}

function segmentsNear(a,b,c,d,reach) {
    const cross=function(p,q,r){return(q.x-p.x)*(r.y-p.y)-(q.y-p.y)*(r.x-p.x)}
    const x1=cross(a,b,c),x2=cross(a,b,d),x3=cross(c,d,a),x4=cross(c,d,b)
    if(x1*x2<=0 && x3*x4<=0 && Math.max(Math.min(a.x,b.x),Math.min(c.x,d.x))<=Math.min(Math.max(a.x,b.x),Math.max(c.x,d.x)) && Math.max(Math.min(a.y,b.y),Math.min(c.y,d.y))<=Math.min(Math.max(a.y,b.y),Math.max(c.y,d.y)))return true
    return Math.min(segmentDistance(a.x,a.y,c,d),segmentDistance(b.x,b.y,c,d),segmentDistance(c.x,c.y,a,b),segmentDistance(d.x,d.y,a,b))<=reach
}

// Match macOS PaperAppearance.displayColor; never change the persisted source colour.
function displayColor(color, mode) {
    if(mode === "original") return color;
    function linear(c) { return c<=0.04045 ? c/12.92 : Math.pow((c+0.055)/1.055,2.4); }
    function srgb(c) { return c<=0.0031308 ? c*12.92 : 1.055*Math.pow(c,1/2.4)-0.055; }
    const channels=[linear(color.r),linear(color.g),linear(color.b)];
    const paper=(mode === "warm" ? [252,247,237] : [36,34,30]).map(function(c){return linear(c/255);});
    const ink=(mode === "warm" ? [48,43,37] : [201,197,189]).map(function(c){return linear(c/255);});
    const lightness=channels[0]*.2126+channels[1]*.7152+channels[2]*.0722;
    const output=channels.map(function(c,i){return srgb(ink[i]+(paper[i]-ink[i])*(mode==="night" ? lightness : c));});
    return Qt.rgba(output[0],output[1],output[2],color.a);
}
