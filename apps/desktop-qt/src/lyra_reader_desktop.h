#pragma once
#include <cstddef>
#include <cstdint>

inline constexpr std::uint32_t LYRA_READER_DESKTOP_ABI_VERSION = 2;

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
