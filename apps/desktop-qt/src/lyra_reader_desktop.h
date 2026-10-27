#pragma once
#include <cstddef>
#include <cstdint>

// Owned Rust allocations: free each Buffer exactly once using buffer_free.
// Output buffers must be zero initialized; calls do not free previous contents.
// All document operations may block and must run on a worker, not the UI thread.
extern "C" {
struct LyraReaderDesktopDocument;
struct LyraReaderRenderSource;
struct LyraReaderBuffer { std::uint8_t *data; std::size_t len; };
struct LyraReaderBitmap {
    std::uint32_t width, height, stride;
    double scale;
    LyraReaderBuffer pixels;
};
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
void lyra_reader_desktop_render_source_free(LyraReaderRenderSource *);
bool lyra_reader_desktop_render_region(const LyraReaderRenderSource *, std::uint32_t page, double scale,
    double x, double y, double width, double height, bool annotated, bool transparent,
    LyraReaderBitmap *output, LyraReaderBuffer *error);
void lyra_reader_desktop_buffer_free(LyraReaderBuffer buffer);
bool lyra_reader_desktop_command(const LyraReaderDesktopDocument *document,
    const std::uint8_t *request, std::size_t request_len, LyraReaderBuffer *output, LyraReaderBuffer *error);
double lyra_reader_desktop_zoom_offset(double offset, double anchor, double old_zoom, double new_zoom);
}
