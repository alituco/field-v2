type OpenBrowserWindow = (url?: string | URL, target?: string) => Window | null;

/**
 * Opens a standalone HTML document and invokes the browser print dialog.
 *
 * Safari may return `null` from `window.open` when `noopener` is supplied in
 * the feature string, even though it still creates a tab. Open the same-origin
 * blank document first, retain the handle long enough to populate it, and then
 * sever `window.opener` explicitly.
 */
export function printStandaloneHtml(
  html: string,
  openWindow: OpenBrowserWindow = window.open.bind(window),
) {
  const printWindow = openWindow("about:blank", "_blank");
  if (!printWindow) return false;

  printWindow.opener = null;
  printWindow.document.open();
  printWindow.document.write(html);
  printWindow.document.close();

  const showPrintDialog = () => {
    printWindow.focus();
    printWindow.print();
  };

  // A freshly written about:blank document is normally complete immediately.
  // The load branch covers slower Safari/WebKit document commits.
  if (printWindow.document.readyState === "complete") {
    printWindow.setTimeout(showPrintDialog, 50);
  } else {
    printWindow.addEventListener(
      "load",
      () => printWindow.setTimeout(showPrintDialog, 50),
      { once: true },
    );
  }

  return true;
}
