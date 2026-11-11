#pragma once
#include <cstddef>
#include <cstdint>

inline constexpr std::uint32_t LYRA_READER_DESKTOP_ABI_VERSION = 12;

// Owned Rust allocations: free each Buffer exactly once using buffer_free.
// Output buffers must be zero initialized; calls do not free previous contents.
// Document operations run on a worker, except the explicitly cache-only selection calls.
extern "C" {
std::uint32_t lyra_reader_desktop_abi_version();
std::size_t lyra_reader_desktop_paper_geometry_limit();
// Invalid input returns NaN; a scroll inside conversation space stores the source cut.
double lyra_reader_desktop_paper_unshifted_scroll(double display_y,double gap_top,double gap);
double lyra_reader_desktop_paper_shifted_scroll(double source_y,double gap_top,double gap);
struct LyraReaderDesktopDocument;
struct LyraReaderRenderSource;
struct LyraReaderDesktopHistory;
struct LyraReaderBuffer { std::uint8_t *data; std::size_t len; };
struct LyraReaderBitmap {
    std::uint32_t width, height, stride;
    double scale;
    LyraReaderBuffer pixels;
};
// Returned page-local point geometry is immutable until its one batch owner is freed.
struct LyraReaderTileRect {double x,y,width,height;};
struct LyraReaderPaperLayout {double height,split,gap;std::uint32_t has_split,reserved;};
struct LyraReaderPaperQuad {LyraReaderTileRect target,source;};
struct LyraReaderPaperQuadPair {std::uint32_t count,reserved;LyraReaderPaperQuad pieces[2];};
struct LyraReaderPaperPoint {double x,y;};
struct LyraReaderPaperHit {std::uint32_t present,reserved;LyraReaderPaperPoint point;};
struct LyraReaderPaperAxis {std::uint32_t present,reserved;double y;};
struct LyraReaderPaperBand {std::uint32_t present,reserved;double top,bottom;};
bool lyra_reader_desktop_paper_band(LyraReaderPaperLayout layout,double top,double bottom,
    LyraReaderPaperBand *output,LyraReaderBuffer *error);
// Pure unclamped anchor map: direction 0=source to display, 1=inverse (absent in gap).
bool lyra_reader_desktop_paper_axis(LyraReaderPaperLayout layout,double y,std::uint32_t direction,
    LyraReaderPaperAxis *output,LyraReaderBuffer *error);
struct LyraReaderPaperRegion {std::uint32_t count,reserved;LyraReaderTileRect bounds,pieces[2];};
// Clips source to original paper; native single-owner controls use bounds, static paint uses
// pieces. Successful count=0 is absent, not an error. Failures leave the output intact.
bool lyra_reader_desktop_paper_region(LyraReaderPaperLayout layout,double width,
    LyraReaderTileRect source,LyraReaderPaperRegion *output,LyraReaderBuffer *error);
// Half-open original paper hit. present=0 denotes a gap/outside; errors leave output intact.
bool lyra_reader_desktop_paper_hit(LyraReaderPaperLayout layout,double width,
    LyraReaderPaperPoint point,LyraReaderPaperHit *output,LyraReaderBuffer *error);
struct LyraReaderPaperSegment {LyraReaderPaperPoint from,to;};
struct LyraReaderPaperSegments {std::uint32_t count,reserved;LyraReaderPaperSegment pieces[2];};
// Clip the raw display sweep to each actual piece of paper, then map back to original points.
// Output is caller-owned/aligned and untouched on failure; it contains at most two segments.
bool lyra_reader_desktop_paper_segments(LyraReaderPaperLayout layout,double width,
    LyraReaderPaperPoint from,LyraReaderPaperPoint to,LyraReaderPaperSegments *output,LyraReaderBuffer *error);
// Pure display geometry. Caller-owned, non-overlapping arrays, at most 256 quads. Geometry
// is page-local 100% view points; no PDF, texture or I/O. Successful mapping allocates nothing. Zero count validates
// layout only and permits null arrays. All outputs stay untouched on invalid input.
bool lyra_reader_desktop_paper_quads(LyraReaderPaperLayout layout,const LyraReaderPaperQuad *input,
    std::size_t count,LyraReaderPaperQuadPair *output,LyraReaderBuffer *error);
struct LyraReaderPlannedTile {std::uint32_t column,row;LyraReaderTileRect target,render;};
struct LyraReaderPagePlan {
    std::uint32_t page;std::int32_t tier;double scale;std::size_t tile_count;
    LyraReaderPlannedTile tiles[96];
};
struct LyraReaderTilePlanBatch {LyraReaderPagePlan *plans;std::size_t len;};
// Density kind 0=tier,1=surface scale/budget; reserved must be zero.
struct LyraReaderTilePlanRequest {
    std::uint32_t page,density_kind;std::int32_t tier;std::uint32_t reserved;
    double width,height;LyraReaderTileRect visible;double required_scale;
    std::uint64_t resident_bytes;
};
// Pure bounded density-grid batch. At most 128 pages/96 tiles per page; no PDFium or I/O.
bool lyra_reader_desktop_plan_tiles(const LyraReaderTilePlanRequest *requests,std::size_t count,
    LyraReaderTilePlanBatch *output,LyraReaderBuffer *error);
void lyra_reader_desktop_tile_plan_free(LyraReaderTilePlanBatch batch);
// Pure bounded history control. The owner must outlive each synchronous borrow;
// retire it once after all commands finish. No PDFium, disk or network operation.
LyraReaderDesktopHistory *lyra_reader_desktop_history_new(LyraReaderBuffer *error);
void lyra_reader_desktop_history_free(LyraReaderDesktopHistory *history);
bool lyra_reader_desktop_history_command(const LyraReaderDesktopHistory *history,
    const std::uint8_t *request,std::size_t request_len,LyraReaderBuffer *output,LyraReaderBuffer *error);
LyraReaderDesktopDocument *lyra_reader_desktop_open(const std::uint8_t *path, std::size_t path_len,
    const std::uint8_t *password, std::size_t password_len, LyraReaderBuffer *error);
void lyra_reader_desktop_close(LyraReaderDesktopDocument *document);
bool lyra_reader_desktop_info(const LyraReaderDesktopDocument *document, LyraReaderBuffer *output, LyraReaderBuffer *error);
bool lyra_reader_desktop_render(const LyraReaderDesktopDocument *document, std::uint32_t page, double scale,
    LyraReaderBitmap *output, LyraReaderBuffer *error);
bool lyra_reader_desktop_render_annotated(const LyraReaderDesktopDocument *document, std::uint32_t page, double scale,
    LyraReaderBitmap *output, LyraReaderBuffer *error);
// Immutable revision. include_edits prepares a verified temporary PDF for printing;
// it never modifies the source PDF or sidecar. Preparation is a worker operation.
LyraReaderRenderSource *lyra_reader_desktop_render_source(const LyraReaderDesktopDocument *, bool include_edits, LyraReaderBuffer *error);
bool lyra_reader_desktop_source_command(const LyraReaderRenderSource *, const std::uint8_t *request,
    std::size_t request_len, LyraReaderBuffer *output, LyraReaderBuffer *error);
// Original bitmap PNG bytes from the pinned immutable source. The UTF-8 identities are
// borrowed during the call; free output/error buffers exactly once with buffer_free.
bool lyra_reader_desktop_source_image_png(const LyraReaderRenderSource *, std::uint32_t page,
    const std::uint8_t *target, std::size_t target_len, const std::uint8_t *revision,
    std::size_t revision_len, LyraReaderBuffer *output, LyraReaderBuffer *error);
void lyra_reader_desktop_render_source_free(LyraReaderRenderSource *);
bool lyra_reader_desktop_render_region(const LyraReaderRenderSource *, std::uint32_t page, double scale,
    double x, double y, double width, double height, bool annotated, bool transparent,
    LyraReaderBitmap *output, LyraReaderBuffer *error);
void lyra_reader_desktop_buffer_free(LyraReaderBuffer buffer);
// Document may be null only for the global audit_records and audit_clear operations.
bool lyra_reader_desktop_command(const LyraReaderDesktopDocument *document,
    const std::uint8_t *request, std::size_t request_len, LyraReaderBuffer *output, LyraReaderBuffer *error);
// These synchronous calls only query prepared text; NotPrepared is distinct from Error.
// Ready owns a UTF-8 buffer; a miss/error leaves output untouched. Endpoints may be reversed.
enum class LyraReaderSelectionStatus : std::uint32_t { Error=0, NotPrepared=1, Ready=2 };
LyraReaderSelectionStatus lyra_reader_desktop_selection_text(const LyraReaderDesktopDocument *,
    std::uint32_t page,std::uint32_t start,std::uint32_t end,LyraReaderBuffer *output,LyraReaderBuffer *error);
std::size_t lyra_reader_desktop_selection_copy_limit();
bool lyra_reader_desktop_selection_copy_text(const std::uint8_t *text,std::size_t text_len,
    LyraReaderBuffer *output,LyraReaderBuffer *error);
// One detached, immutable crop pair; all dimensions are checked before allocating.
// Each output owns pixels freed once with buffer_free. Null/aliased/misaligned outputs fail.
std::size_t lyra_reader_desktop_drag_pair_limit();
bool lyra_reader_desktop_drag_preview(const LyraReaderRenderSource *,std::uint32_t page,
    const std::uint8_t *target,std::size_t target_len,const std::uint8_t *revision,std::size_t revision_len,
    double x,double y,double width,double height,double scale,
    LyraReaderBitmap *background,LyraReaderBitmap *foreground,LyraReaderBuffer *error);
double lyra_reader_desktop_zoom_offset(double offset, double anchor, double old_zoom, double new_zoom);
// Pure shared policy: zero means no fit/no change, never a valid percentage.
std::uint32_t lyra_reader_desktop_fit_percent(bool fit_page, double page_width, double page_height,
    double viewport_width, double viewport_height, double calibration);
std::uint32_t lyra_reader_desktop_viewport_fit(std::uint32_t page_count, std::uint32_t current_percent,
    double page_width, double page_height, double viewport_width, double viewport_height, double calibration);
// NaN means no usable transient layout range; retain the previous offset.
struct LyraReaderFitPageSpacing { double inset_pt; double gap_pt; };
LyraReaderFitPageSpacing lyra_reader_desktop_fit_page_spacing(double page_height, double viewport_height,
    double zoom, double preferred_gap);
double lyra_reader_desktop_clamp_scroll(double offset, double content_height, double viewport_height);
}
