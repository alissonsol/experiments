// Copyright (c) 2025 - Alisson Sol
//
/**
 * Represents a Windows service with its configuration and state.
 */
type Service = {
  name: string;
  description: string;
  status: string;
  start_mode: string;
  end_mode?: string;
  log_on_as: string;
  path: string;
};

// Configuration constants
const BIND_ADDRESS = '127.0.0.1:4000';
const API_BASE = `http://${BIND_ADDRESS}`;
const SAVE_DEBOUNCE_MS = 300; // Debounce save operations to reduce backend load

const app = document.getElementById('app')!;

// Loader animation controls — spiral animation from center to border
let loaderRaf = 0;
let loaderRunning = false;
let loaderEl: HTMLElement | null = null;
let loaderTextEl: HTMLElement | null = null;

/**
 * Starts the animated loader with a spiral animation from center to border.
 * The animation continues in a loop, returning to center when it reaches the border.
 */
function startLoader() {
  if (loaderRunning) return;
  loaderEl = document.getElementById('loader');
  loaderTextEl = loaderEl?.querySelector('.loader-text') as HTMLElement | null;
  if (!loaderEl || !loaderTextEl) return;
  loaderRunning = true;

  const DURATION = 5000; // Seconds to reach the border
  const ROTATIONS = 6; // number of spiral turns
  let startTime: number | null = null;

  function getMaxRadius() {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const rect = loaderTextEl!.getBoundingClientRect();
    const margin = 8;
    const halfW = vw / 2;
    const halfH = vh / 2;
    // distance to nearest border from center, minus half of element and margin
    const maxX = halfW - rect.width / 2 - margin;
    const maxY = halfH - rect.height / 2 - margin;
    return Math.max(0, Math.min(maxX, maxY));
  }

  function step(ts: number) {
    if (!loaderRunning) return;

    if (!startTime) startTime = ts;
    const elapsed = ts - startTime;
    const t = Math.min(elapsed, DURATION);
    const frac = t / DURATION;

    const maxR = getMaxRadius();
    const r = frac * maxR;
    const theta = frac * ROTATIONS * Math.PI * 2;
    const x = r * Math.cos(theta);
    const y = r * Math.sin(theta);

    loaderTextEl!.style.transform = `translate(-50%,-50%) translate(${x}px, ${y}px)`;

    if (elapsed >= DURATION) {
      // reached border. If loader still present, restart from center
      startTime = ts;
    }

    loaderRaf = requestAnimationFrame(step);
  }

  // Start the spiral animation
  loaderTextEl.style.willChange = 'transform';
  loaderRaf = requestAnimationFrame(step);
  window.addEventListener('resize', onLoaderResize);
}

function onLoaderResize() {
  // Reset animation on resize so it restarts from center with new dimensions
  // The next animation frame will pick up the new dimensions
}

/**
 * Stops the loader animation and removes it from the DOM with a fade-out effect.
 */
function stopLoader() {
  if (!loaderRunning) return;
  loaderRunning = false;
  cancelAnimationFrame(loaderRaf);
  window.removeEventListener('resize', onLoaderResize);
  if (loaderEl) {
    loaderEl.classList.add('fade-out');
    setTimeout(() => loaderEl?.remove(), 360);
  }
}

/**
 * Creates an HTML element with optional class and text content.
 * Utility function to reduce boilerplate in DOM creation.
 * @param tag - The HTML tag name
 * @param cls - Optional CSS class name(s)
 * @param txt - Optional text content
 * @returns The created HTML element
 */
function createElement<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  cls?: string,
  txt?: string
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt) e.textContent = txt;
  return e;
}

// Alias for backward compatibility and brevity
const el = createElement;

function showUnsupported() {
  const modal = el('div', 'modal');
  const box = el('div', 'box');
  box.innerHTML = `<h2>Unsupported OS</h2><p>Ordem runs only on Microsoft Windows. Please run this application on Windows.</p>`;
  const ok = el('button', 'btn');
  ok.textContent = 'OK';
  ok.onclick = () => {
    modal.remove();
    try { window.location.href = 'about:blank'; } catch {}
  };
  box.appendChild(ok);
  modal.appendChild(box);
  document.body.appendChild(modal);
}

/**
 * Detects if the client is running on Windows based on the user agent.
 * @returns true if running on Windows, false otherwise
 */
const isWindowsClient = () => navigator.userAgent.includes('Windows');

/**
 * Fetches JSON data from the backend API.
 * @param url - The API endpoint URL (relative or absolute)
 * @returns Promise resolving to the parsed JSON response
 * @throws Error if the request fails
 */
async function fetchJSON<T>(url: string): Promise<T> {
  const fetchUrl = url.startsWith('http') ? url : API_BASE + url;
  const res = await fetch(fetchUrl);
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

// Debouncing for save operations
let saveTimeout: number | null = null;

/**
 * Saves the target service configurations to the backend with debouncing.
 * Debouncing reduces backend load during rapid changes by batching requests.
 * @param targets - Array of service configurations to save
 */
async function saveTargets(targets: Service[]) {
  // Clear previous timeout to implement debouncing
  if (saveTimeout !== null) {
    clearTimeout(saveTimeout);
  }

  saveTimeout = window.setTimeout(async () => {
    try {
      await fetch(API_BASE + '/api/targets', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(targets),
      });
    } catch (e) {
      console.error('Failed to save targets:', e);
    }
  }, SAVE_DEBOUNCE_MS);
}

/**
 * Saves pruned target service configurations to the backend.
 * Only saves services where start_mode differs from end_mode.
 * This operation is immediate (not debounced) as it's user-triggered.
 * @param targets - Array of service configurations to filter and save
 */
async function savePrunedTargets(targets: Service[]) {
  try {
    await fetch(API_BASE + '/api/targets-pruned', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(targets),
    });
  } catch (e) {
    console.error('Failed to save pruned targets:', e);
  }
}

const STARTUP_TYPES = ['Automatic (Delayed Start)', 'Automatic', 'Manual', 'Disabled'] as const;

const HEADER_COLUMNS = [
  { label: '#', className: 'col-num' },
  { label: 'Name', className: 'col-name' },
  { label: 'Description', className: 'col-desc' },
  { label: 'Status', className: 'col-status' },
  { label: 'Startup Mode', className: 'col-startup' },
  { label: 'Log On As', className: 'col-logon' },
  { label: 'Path', className: 'col-path' },
] as const;

const HEADER_COLUMNS_RIGHT = [
  { label: '#', className: 'col-num' },
  { label: 'Name', className: 'col-name' },
  { label: 'Description', className: 'col-desc' },
  { label: 'Status', className: 'col-status' },
  { label: 'Startup Mode', className: 'col-startup' },
  { label: 'End Mode', className: 'col-endmode' },
  { label: 'Log On As', className: 'col-logon' },
  { label: 'Path', className: 'col-path' },
] as const;

/**
 * Normalizes a service startup mode string to one of the standard types.
 * Uses fast-path checking for already normalized values, with fallback for legacy formats.
 * @param value - The raw startup mode string
 * @returns Normalized startup mode string
 */
function mapStartMode(value: string): string {
  if (!value) return 'Manual';

  // Fast path: check if value is already normalized
  if (STARTUP_TYPES.includes(value as any)) return value;

  // Fallback for legacy or unexpected values
  const lower = value.toLowerCase();
  if (lower.includes('auto') && lower.includes('del')) return 'Automatic (Delayed Start)';
  if (lower.includes('auto')) return 'Automatic';
  if (lower.includes('disabled')) return 'Disabled';
  return 'Manual';
}

/**
 * Creates a select element populated with startup type options.
 * @param className - CSS class name for the select element
 * @param value - The initial selected value
 * @returns Configured HTMLSelectElement
 */
function createSelect(className: string, value: string): HTMLSelectElement {
  const select = el('select', className);
  STARTUP_TYPES.forEach(v => {
    const option = el('option');
    option.value = option.text = v;
    select.add(option);
  });
  select.value = value;
  return select;
}

/**
 * Creates an editable service row for the target pane.
 * @param s - Service data
 * @param index - Index in the services array
 * @param rowNumber - Display row number (1-indexed)
 * @param onStartupChange - Callback for startup mode changes
 * @param onEndTypeChange - Callback for end mode changes
 * @returns Configured row element with drag-and-drop support
 */
function createEditableServiceRow(
  s: Service,
  index: number,
  rowNumber: number,
  onStartupChange: (i: number, val: string) => void,
  onEndTypeChange: (i: number, val: string) => void
) {
  const row = el('div', 'row');
  row.draggable = true;
  row.dataset.index = String(index);

  const startup = createSelect('col-startup select', mapStartMode(s.start_mode));
  const endtype = createSelect('col-endmode select', mapStartMode(s.end_mode || s.start_mode));

  // Update endtype background based on comparison
  const updateEndModeHighlight = () => {
    endtype.classList.toggle('different', startup.value !== endtype.value);
  };

  updateEndModeHighlight();

  startup.onchange = () => {
    onStartupChange(index, startup.value);
    updateEndModeHighlight();
  };

  endtype.onchange = () => {
    onEndTypeChange(index, endtype.value);
    updateEndModeHighlight();
  };

  row.append(
    el('div', 'drag-handle', '☰'),
    el('div', 'col-num', String(rowNumber)),
    el('div', 'col-name', s.name),
    el('div', 'col-desc muted', s.description || ''),
    el('div', 'col-status', s.status),
    startup,
    endtype,
    el('div', 'col-logon', s.log_on_as || ''),
    el('div', 'col-path muted', s.path || '')
  );

  return row;
}

function createHeaderRow(includesDragHandle: boolean, isRightPane: boolean = false) {
  const header = el('div', 'row header');

  if (includesDragHandle) {
    const dragHandle = el('div', 'drag-handle', '');
    header.appendChild(dragHandle);
  }

  const columns = isRightPane ? HEADER_COLUMNS_RIGHT : HEADER_COLUMNS;
  columns.forEach(col => {
    const headerCol = el('div', col.className, col.label);
    headerCol.classList.add('resizable');

    // Add resize handle
    const resizeHandle = el('div', 'resize-handle');
    headerCol.appendChild(resizeHandle);

    header.appendChild(headerCol);
  });

  return header;
}

function createServiceRow(s: Service, idx: number) {
  const row = el('div', 'row');
  row.append(
    el('div', 'col-num', String(idx + 1)),
    el('div', 'col-name', s.name),
    el('div', 'col-desc muted', s.description || ''),
    el('div', 'col-status', s.status),
    el('div', 'col-startup', s.start_mode),
    el('div', 'col-logon', s.log_on_as),
    el('div', 'col-path muted', s.path)
  );
  return row;
}

function renderApp(current: Service[], targets: Service[]) {
  app.innerHTML = '';
  const root = el('div', 'app');
  const toolbar = el('div', 'toolbar');
  const toolbarTitle = el('div', 'toolbar-title', 'Ordem — Service ordering and target startup modes');
  const toolbarLeft = el('div', 'toolbar-group');
  const toolbarRight = el('div', 'toolbar-group');
  toolbar.append(toolbarLeft, toolbarTitle, toolbarRight);
  root.appendChild(toolbar);
  const content = el('div', 'content');

  // Left pane (Current services)
  const leftPane = el('div', 'pane left-pane');
  leftPane.appendChild(el('div', 'title', 'Current'));

  const leftHeader = el('div', 'header-container');
  const leftHeaderRow = createHeaderRow(false);
  leftHeader.appendChild(leftHeaderRow);
  leftPane.appendChild(leftHeader);

  const llist = el('div', 'list');
  current.forEach((s, idx) => llist.appendChild(createServiceRow(s, idx)));
  leftPane.appendChild(llist);

  // Sync horizontal scroll between header and list
  llist.addEventListener('scroll', () => {
    leftHeader.scrollLeft = llist.scrollLeft;
  });

  // Right pane (Target services)
  const rightPane = el('div', 'pane right-pane');
  rightPane.appendChild(el('div', 'title', 'Target'));

  const rightHeader = el('div', 'header-container');
  const rightHeaderRow = createHeaderRow(true, true);
  rightHeader.appendChild(rightHeaderRow);
  rightPane.appendChild(rightHeader);

  const rlist = el('div', 'list');
  let items = targets.slice();

  // Sync horizontal scroll between header and list
  rlist.addEventListener('scroll', () => {
    rightHeader.scrollLeft = rlist.scrollLeft;
  });

  // Setup column resizing for both panes
  setupColumnResize(leftHeaderRow, 'left-pane');
  setupColumnResize(rightHeaderRow, 'right-pane');

  /**
   * Synchronizes column widths from header to data rows for a specific pane.
   * Uses batched read/write operations to minimize layout thrashing and improve performance.
   * @param headerRow - The header row element containing column definitions
   * @param paneClass - CSS class identifying the pane to update
   */
  function syncPaneWidths(headerRow: HTMLElement, paneClass: string) {
    const headerCols = headerRow.querySelectorAll('[class^="col-"], .drag-handle');
    const updates: Array<{colClass: string, width: string}> = [];

    // Batch read operations to avoid layout thrashing
    headerCols.forEach((headerCol) => {
      const col = headerCol as HTMLElement;
      const colClass = col.className.split(' ')[0];
      const headerWidth = col.style.width || `${col.offsetWidth}px`;
      updates.push({colClass, width: headerWidth});
    });

    // Batch write operations for optimal performance
    for (const {colClass, width} of updates) {
      const cells = document.querySelectorAll(`.${paneClass} .row .${colClass}`);
      for (let i = 0; i < cells.length; i++) {
        (cells[i] as HTMLElement).style.width = width;
      }
    }
  }

  // Sync initial column widths from headers to data rows
  function syncInitialWidths() {
    requestAnimationFrame(() => {
      syncPaneWidths(leftHeaderRow, 'left-pane');
      syncPaneWidths(rightHeaderRow, 'right-pane');
    });
  }

  // Synchronize row heights between panes
  function syncRowHeights() {
    requestAnimationFrame(() => {
      const firstRow = rlist.querySelector('.row:not(.header)') as HTMLElement;
      if (firstRow) {
        const height = `${Math.max(36, firstRow.offsetHeight)}px`;
        document.querySelectorAll('.row:not(.header)').forEach((row) => {
          (row as HTMLElement).style.height = height;
        });
      }
    });
  }

  // Setup column resizing
  function setupColumnResize(headerRow: HTMLElement, paneClass: string) {
    headerRow.querySelectorAll('.resizable').forEach((col) => {
      const resizeHandle = col.querySelector('.resize-handle') as HTMLElement;
      if (!resizeHandle) return;

      resizeHandle.addEventListener('mousedown', (e) => {
        e.preventDefault();
        e.stopPropagation();

        const headerCol = col as HTMLElement;
        const startX = e.pageX;
        const startWidth = headerCol.offsetWidth;
        const colClass = headerCol.className.split(' ')[0];
        const cells = document.querySelectorAll(`.${paneClass} .row .${colClass}`);
        const cellCount = cells.length;

        const onMouseMove = (e: MouseEvent) => {
          const width = Math.max(50, startWidth + (e.pageX - startX));
          const widthPx = `${width}px`;
          headerCol.style.width = widthPx;

          // Use for loop instead of forEach for better performance
          for (let i = 0; i < cellCount; i++) {
            (cells[i] as HTMLElement).style.width = widthPx;
          }
        };

        const onMouseUp = () => {
          document.removeEventListener('mousemove', onMouseMove);
          document.removeEventListener('mouseup', onMouseUp);
        };

        document.addEventListener('mousemove', onMouseMove);
        document.addEventListener('mouseup', onMouseUp);
      });
    });
  }

  /**
   * Implements drag-and-drop with auto-scroll support.
   * Auto-scrolls the container when dragging near the edges for better UX.
   */
  let autoScrollInterval: number | null = null;

  const startAutoScroll = (container: HTMLElement, direction: 'up' | 'down') => {
    if (autoScrollInterval !== null) return;

    const scrollSpeed = 10;
    autoScrollInterval = window.setInterval(() => {
      if (direction === 'up') {
        container.scrollTop = Math.max(0, container.scrollTop - scrollSpeed);
      } else {
        container.scrollTop = Math.min(
          container.scrollHeight - container.clientHeight,
          container.scrollTop + scrollSpeed
        );
      }
    }, 16);
  };

  const stopAutoScroll = () => {
    if (autoScrollInterval !== null) {
      clearInterval(autoScrollInterval);
      autoScrollInterval = null;
    }
  };

  rlist.addEventListener('dragstart', (ev) => {
    const row = (ev.target as HTMLElement).closest('.row') as HTMLElement;
    if (row) ev.dataTransfer!.setData('text/plain', row.dataset.index!);
  });

  rlist.addEventListener('dragover', (ev) => {
    const row = (ev.target as HTMLElement).closest('.row');
    if (!row) {
      stopAutoScroll();
      return;
    }

    ev.preventDefault();

    // Auto-scroll when dragging near edges
    const rect = rlist.getBoundingClientRect();
    const scrollZone = 50; // pixels from edge to trigger scroll
    const mouseY = ev.clientY;

    if (mouseY < rect.top + scrollZone) {
      startAutoScroll(rlist, 'up');
    } else if (mouseY > rect.bottom - scrollZone) {
      startAutoScroll(rlist, 'down');
    } else {
      stopAutoScroll();
    }
  });

  rlist.addEventListener('dragleave', (ev) => {
    if (ev.target === rlist) {
      stopAutoScroll();
    }
  });

  rlist.addEventListener('drop', (ev) => {
    stopAutoScroll();

    const row = (ev.target as HTMLElement).closest('.row') as HTMLElement;
    if (!row) return;
    ev.preventDefault();
    const from = Number(ev.dataTransfer!.getData('text/plain'));
    const to = Number(row.dataset.index!);
    if (!isNaN(from) && !isNaN(to) && from !== to) {
      const [item] = items.splice(from, 1);
      items.splice(to, 0, item);
      rebuildRight();
      saveTargets(items);
    }
  });

  rlist.addEventListener('dragend', () => {
    stopAutoScroll();
  });

  const handleStartupChange = (idx: number, val: string) => {
    items[idx].start_mode = val;
    saveTargets(items);
  };

  const handleEndTypeChange = (idx: number, val: string) => {
    items[idx].end_mode = val;
    saveTargets(items);
  };

  function rebuildRight() {
    // Use DocumentFragment for better performance
    const fragment = document.createDocumentFragment();
    items.forEach((s, i) => {
      fragment.appendChild(createEditableServiceRow(s, i, i + 1, handleStartupChange, handleEndTypeChange));
    });
    rlist.innerHTML = '';
    rlist.appendChild(fragment);
    syncRowHeights();
    syncInitialWidths();
  }

  rebuildRight();
  rightPane.appendChild(rlist);

  // Toggle pane controls
  const toggleLeft = el('button', 'btn', 'Toggle Left');
  const toggleRight = el('button', 'btn', 'Toggle Right');

  const togglePane = (paneToExpand: HTMLElement, paneToHide: HTMLElement, buttonToHide: HTMLElement) => {
    const isExpanded = !paneToExpand.classList.contains('expanded');
    paneToExpand.classList.toggle('expanded', isExpanded);
    paneToHide.classList.toggle('hidden', isExpanded);
    buttonToHide.classList.toggle('hidden', isExpanded);
  };

  toggleLeft.onclick = () => togglePane(leftPane, rightPane, toggleRight);
  toggleRight.onclick = () => togglePane(rightPane, leftPane, toggleLeft);

  // Manual Startup Mode button
  const manualStartupType = el('button', 'btn btn-reset', 'Manual Startup Mode');
  manualStartupType.onclick = async () => {
    items.forEach(s => s.start_mode = 'Manual');
    await saveTargets(items);
    rebuildRight();
  };

  // Reset Target button
  const resetTarget = el('button', 'btn btn-reset', 'Reset Target');
  resetTarget.onclick = async () => {
    if (confirm('Reset targets to match current state? This will overwrite all target configurations.')) {
      items = current.slice().map(s => ({ ...s, end_mode: s.start_mode }));
      await saveTargets(items);
      rebuildRight();
    }
  };

  // Prune Output button
  const pruneOutput = el('button', 'btn btn-reset', 'Prune Output');
  pruneOutput.onclick = async () => {
    if (confirm('Save only services where End Mode differs from Startup Mode?')) {
      await savePrunedTargets(items);
    }
  };

  toolbarLeft.append(toggleLeft, toggleRight);
  toolbarRight.append(manualStartupType, resetTarget, pruneOutput);
  content.append(leftPane, rightPane);
  root.append(toolbar, content);
  app.appendChild(root);

  // Sync row heights and column widths after DOM is rendered
  syncRowHeights();
  syncInitialWidths();
}

/**
 * Application entry point. Initializes the UI and loads service data from the backend.
 * Displays a loader during data fetching and handles errors gracefully.
 */
async function start() {
  // Start loader animation while we fetch backend data
  startLoader();
  if (!isWindowsClient()) {
    showUnsupported();
    stopLoader();
    return;
  }
  try {
    // Fetch current services and saved targets in parallel for better performance
    const [current, targets] = await Promise.all([
      fetchJSON<Service[]>('/api/services'),
      fetchJSON<Service[]>('/api/targets'),
    ]);
    // Ensure end_mode is initialized if missing
    const normalizedTargets = targets.map(s => ({
      ...s,
      end_mode: s.end_mode || s.start_mode
    }));
    renderApp(current, normalizedTargets);
    // Data is ready — stop the loader animation
    stopLoader();
  } catch (e) {
    app.innerHTML = `<div style="padding:20px">Error: ${(e as Error).message}</div>`;
    console.error(e);
    stopLoader();
  }
}

start();

