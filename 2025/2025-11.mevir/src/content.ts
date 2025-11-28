import { LinkInfo, PageContent } from './types';

const MAX_TEXT_SIZE = 1024 * 1024; // 1 megabyte

/**
 * Extracts URI scheme from a URL
 */
function extractUriScheme(url: string): string {
  try {
    const parsedUrl = new URL(url, window.location.href);
    return parsedUrl.protocol.replace(':', '');
  } catch {
    return 'unknown';
  }
}

/**
 * Extracts all text content from the page, including divs and frames
 */
function extractPageText(): { text: string; isTextCut: boolean } {
  let text = '';
  let isTextCut = false;

  // Extract text from main document
  const extractText = (doc: Document): string => {
    const body = doc.body;
    if (!body) return '';

    // Clone the body so we don't modify the live DOM
    const clone = body.cloneNode(true) as HTMLElement;

    // Remove elements that may contain code or non-user-visible text
    // such as scripts, styles, code blocks, preformatted code, templates, and noscript
    const selectors = 'script, style, code, pre, template, noscript';
    clone.querySelectorAll(selectors).forEach((el) => el.remove());

    // Also remove any elements with type attributes that commonly contain code
    clone.querySelectorAll('[type="application/javascript"],[type="text/javascript"]').forEach((el) => el.remove());

    // Get rendered text from the cleaned clone. `innerText` prefers visible text.
    return clone.innerText || clone.textContent || '';
  };

  // Main document text
  text = extractText(document);

  // Try to extract text from iframes (same-origin only)
  try {
    const iframes = document.querySelectorAll('iframe');
    iframes.forEach((iframe) => {
      try {
        const iframeDoc = iframe.contentDocument || iframe.contentWindow?.document;
        if (iframeDoc) {
          text += '\n' + extractText(iframeDoc);
        }
      } catch {
        // Cross-origin iframe, skip
      }
    });
  } catch {
    // Ignore iframe access errors
  }

  // Truncate if exceeds 1MB
  if (text.length > MAX_TEXT_SIZE) {
    text = text.substring(0, MAX_TEXT_SIZE);
    isTextCut = true;
  }

  return { text, isTextCut };
}

/**
 * Extracts all links from the page
 */
function extractLinks(): LinkInfo[] {
  const links: LinkInfo[] = [];
  const seenUrls = new Set<string>();

  const processLinks = (doc: Document) => {
    const anchors = doc.querySelectorAll('a[href]');
    anchors.forEach((anchor) => {
      const href = anchor.getAttribute('href');
      if (href && !seenUrls.has(href)) {
        seenUrls.add(href);
        links.push({
          LinkUrl: href,
          LinkType: extractUriScheme(href)
        });
      }
    });
  };

  // Process main document
  processLinks(document);

  // Try to process iframes (same-origin only)
  try {
    const iframes = document.querySelectorAll('iframe');
    iframes.forEach((iframe) => {
      try {
        const iframeDoc = iframe.contentDocument || iframe.contentWindow?.document;
        if (iframeDoc) {
          processLinks(iframeDoc);
        }
      } catch {
        // Cross-origin iframe, skip
      }
    });
  } catch {
    // Ignore iframe access errors
  }

  return links;
}

/**
 * Creates PageContent from the current page
 */
function createPageContent(): PageContent {
  const { text, isTextCut } = extractPageText();
  const links = extractLinks();

  return {
    Text: text,
    IsTextCut: isTextCut,
    LinksCount: links.length,
    Links: links
  };
}

/**
 * Main content script initialization
 */
function init() {
  const pageContent = createPageContent();
  
  // Send page content to background script
  chrome.runtime.sendMessage({
    type: 'PAGE_CONTENT',
    data: pageContent
  }).catch(() => {
    // Extension context may be invalidated, ignore
  });
}

// Run when page is fully loaded
if (document.readyState === 'complete') {
  init();
} else {
  window.addEventListener('load', init);
}

