//! Typed, allocation-free paper-quad batch control for the Qt scene graph.
use crate::tile_plan::Rect;
use lyra_reader_session::paper::{PaperLayout, PaperQuad};

pub const MAX_QUADS: usize = 256;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Layout {
    pub height: f64,
    pub split: f64,
    pub gap: f64,
    pub has_split: u32,
    pub reserved: u32,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Quad {
    pub target: Rect,
    pub source: Rect,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Pair {
    pub count: u32,
    pub reserved: u32,
    pub pieces: [Quad; 2],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Hit {
    pub present: u32,
    pub reserved: u32,
    pub point: Point,
}
const _: () = assert!(std::mem::size_of::<Hit>() == 24);
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Region {
    pub count: u32,
    pub reserved: u32,
    pub bounds: Rect,
    pub pieces: [Rect; 2],
}
const _: () = assert!(std::mem::size_of::<Region>() == 104);
pub fn region(layout: Layout, width: f64, source: Rect) -> Result<Region, String> {
    let mapped = PaperLayout::try_from(layout)?
        .region(width, source.into())
        .map_err(|e| e.to_string())?;
    // Absent geometry has count zero; initialize its excluded storage rather than exposing
    // uninitialized coordinates across the boundary.
    let empty = Rect {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };
    let mut out = Region {
        count: 0,
        reserved: 0,
        bounds: mapped.bounds.map(Rect::from).unwrap_or(empty),
        pieces: [empty; 2],
    };
    for rect in mapped.pieces.into_iter().flatten() {
        out.pieces[out.count as usize] = rect.into();
        out.count += 1;
    }
    Ok(out)
}
pub fn hit(layout: Layout, width: f64, point: Point) -> Result<Hit, String> {
    let mapped = PaperLayout::try_from(layout)?
        .pointer_point(width, lyra_reader_core::Point::new(point.x, point.y))
        .map_err(|e| e.to_string())?;
    Ok(Hit {
        present: u32::from(mapped.is_some()),
        reserved: 0,
        point: mapped
            .map(|p| Point { x: p.x, y: p.y })
            .unwrap_or(Point { x: 0.0, y: 0.0 }),
    })
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Segment {
    pub from: Point,
    pub to: Point,
}
#[repr(C)]
pub struct Segments {
    pub count: u32,
    pub reserved: u32,
    pub pieces: [Segment; 2],
}
const _: () = assert!(std::mem::size_of::<Segments>() == 72);
pub fn segments(layout: Layout, width: f64, from: Point, to: Point) -> Result<Segments, String> {
    let p = |v: Point| lyra_reader_core::Point::new(v.x, v.y);
    let mapped = PaperLayout::try_from(layout)?
        .pointer_segments(width, p(from), p(to))
        .map_err(|e| e.to_string())?;
    let mut output = Segments {
        count: 0,
        reserved: 0,
        pieces: [Segment {
            from: Point { x: 0.0, y: 0.0 },
            to: Point { x: 0.0, y: 0.0 },
        }; 2],
    };
    for line in mapped.into_iter().flatten() {
        output.pieces[output.count as usize] = Segment {
            from: Point {
                x: line.from.x,
                y: line.from.y,
            },
            to: Point {
                x: line.to.x,
                y: line.to.y,
            },
        };
        output.count += 1;
    }
    Ok(output)
}
const _: () = assert!(std::mem::size_of::<Layout>() == 32);
const _: () = assert!(std::mem::size_of::<Quad>() == 64);
const _: () = assert!(std::mem::size_of::<Pair>() == 136);

impl From<Rect> for lyra_reader_core::Rect {
    fn from(r: Rect) -> Self {
        Self::new(r.x, r.y, r.width, r.height)
    }
}
impl From<lyra_reader_core::Rect> for Rect {
    fn from(r: lyra_reader_core::Rect) -> Self {
        Self {
            x: r.min_x(),
            y: r.min_y(),
            width: r.size.width,
            height: r.size.height,
        }
    }
}
impl From<Quad> for PaperQuad {
    fn from(q: Quad) -> Self {
        Self {
            target: q.target.into(),
            source: q.source.into(),
        }
    }
}
impl From<PaperQuad> for Quad {
    fn from(q: PaperQuad) -> Self {
        Self {
            target: q.target.into(),
            source: q.source.into(),
        }
    }
}
impl TryFrom<Layout> for PaperLayout {
    type Error = String;
    fn try_from(layout: Layout) -> Result<Self, String> {
        if layout.reserved != 0
            || layout.has_split > 1
            || layout.has_split == 0 && layout.split != 0.0
        {
            return Err("Invalid paper-layout flags".into());
        }
        Self::new(
            layout.height,
            (layout.has_split == 1).then_some(layout.split),
            layout.gap,
        )
        .map_err(|e| e.to_string())
    }
}

pub fn map(layout: Layout, input: &[Quad], output: &mut [Pair]) -> Result<(), String> {
    if input.len() > MAX_QUADS || output.len() != input.len() {
        return Err("Invalid paper-quad batch size".into());
    }
    let paper = PaperLayout::try_from(layout)?;
    // Validate the entire immutable input before publishing any output. The second small
    // arithmetic pass avoids allocating a temporary batch on every scene-graph update.
    for q in input {
        paper.quads((*q).into()).map_err(|e| e.to_string())?;
    }
    for (q, out) in input.iter().zip(output) {
        let pieces = paper.quads((*q).into()).map_err(|e| e.to_string())?;
        let first: Quad = pieces.first.into();
        *out = Pair {
            count: if pieces.second.is_some() { 2 } else { 1 },
            reserved: 0,
            // The tail is excluded by count; keeping initialized geometry avoids exposing
            // padding/uninitialized values if a native diagnostic inspects the packet.
            pieces: [first, pieces.second.map(Quad::from).unwrap_or(first)],
        };
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn layout() -> Layout {
        Layout {
            height: 12.0,
            split: 4.0,
            gap: 3.0,
            has_split: 1,
            reserved: 0,
        }
    }
    pub(crate) fn quad() -> Quad {
        Quad {
            target: Rect {
                x: 0.0,
                y: 0.0,
                width: 8.0,
                height: 12.0,
            },
            source: Rect {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
        }
    }
    pub(crate) fn untouched() -> Pair {
        Pair {
            count: 99,
            reserved: 98,
            pieces: [quad(); 2],
        }
    }
    #[test]
    fn typed_batch_uses_original_uvs_and_all_outputs_are_atomic() {
        let mut output = [untouched(); 2];
        let original = quad();
        map(layout(), &[original, original], &mut output).unwrap();
        assert_eq!(output[0].count, 2);
        assert_eq!(output[0].pieces[0].target.height, 4.0);
        assert_eq!(output[0].pieces[1].target.y, 7.0);
        assert_eq!(output[0].pieces[1].target.height, 8.0);
        assert_eq!(output[0].pieces[1].source.y, 1.0 / 3.0);
        let mut bad = quad();
        bad.source.width = f64::NAN;
        output = [untouched(); 2];
        assert!(map(layout(), &[original, bad], &mut output).is_err());
        assert!(output.iter().all(|p| p.count == 99 && p.reserved == 98));
    }
    #[test]
    fn flags_bounds_and_empty_validation_are_explicit() {
        assert!(map(layout(), &[], &mut []).is_ok());
        for bad in [
            Layout {
                reserved: 1,
                ..layout()
            },
            Layout {
                has_split: 2,
                ..layout()
            },
            Layout {
                has_split: 0,
                ..layout()
            },
            Layout {
                gap: f64::NAN,
                ..layout()
            },
        ] {
            assert!(map(bad, &[], &mut []).is_err());
        }
        assert!(
            map(
                layout(),
                &[quad(); MAX_QUADS + 1],
                &mut [untouched(); MAX_QUADS + 1]
            )
            .is_err()
        );
        assert!(map(layout(), &[quad()], &mut []).is_err());
    }
}
