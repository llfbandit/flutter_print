## 0.3.0
* feat: Add page range print option (PDF, image, text).
* feat: Add Pages selector to the print dialog.
* feat: Fail with INVALID_PAGE_RANGE when no page matches.
* fix: Report print errors from printPreview.

## 0.2.0
* feat: Make print options nullable to get system defaults.
* fix: Decode image once not per copy.
* fix: Avoid redundant file read.
* fix: Init GDI+ once
* fix: Run print job off the platform thread
* fix: silent fallback to 1 copy.
* fix: Opens default app for preview instead of misleading custom dialog.

## 0.1.0
* feat: Add custom preview dialog with fluent_ui (there's no way for preview print on windows).
* chore: Multiple code improvements/additions.