#pragma once
#include <cstddef>
#include <cstdint>

inline constexpr std::uint32_t LYRA_READER_DESKTOP_ABI_VERSION = 3;

// Owned Rust allocations: free each Buffer exactly once using buffer_free.
// Output buffers must be zero initialized; calls do not free previous contents.
// All document operations may block and must run on a worker, not the UI thread.
extern "C" {
std::uint32_t lyra_reader_desktop_abi_version();
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
double lyra_reader_desktop_zoom_offset(double offset, double anchor, double old_zoom, double new_zoom);
// Pure shared policy: zero means no fit/no change, never a valid percentage.
std::uint32_t lyra_reader_desktop_fit_percent(bool fit_page, double page_width, double page_height,
    double viewport_width, double viewport_height, double calibration);
std::uint32_t lyra_reader_desktop_viewport_fit(std::uint32_t page_count, std::uint32_t current_percent,
    double page_height, double viewport_height, double calibration);
// NaN means no usable transient layout range; retain the previous offset.
double lyra_reader_desktop_clamp_scroll(double offset, double content_height, double viewport_height);
}
