type Service = {
  name: string;
  description: string;
  status: string;
  startup_type: string;
  end_type?: string;
  log_on_as: string;
  path: string;
};

// Backend base URL — change if your backend runs elsewhere
const API_BASE = 'http://127.0.0.1:4000';

const app = document.getElementById('app')!;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  cls?: string,
  txt?: string
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (txt) e.textContent = txt;
  return e;
}

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

const isWindowsClient = () => navigator.userAgent.includes('Windows');

async function fetchJSON<T>(url: string): Promise<T> {
  const fetchUrl = url.startsWith('http') ? url : API_BASE + url;
  const res = await fetch(fetchUrl);
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

async function saveTargets(targets: Service[]) {
  try {
    await fetch(API_BASE + '/api/targets', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(targets),
    });
  } catch (e) {
    console.error('Failed to save targets', e);
  }
}

const STARTUP_TYPES = ['Automatic (Delayed Start)', 'Automatic', 'Manual', 'Disabled'] as const;

const HEADER_COLUMNS = [
  { label: '#', className: 'col-num' },
  { label: 'Name', className: 'col-name' },
  { label: 'Description', className: 'col-desc' },
  { label: 'Status', className: 'col-status' },
  { label: 'Startup Type', className: 'col-startup' },
  { label: 'Log On As', className: 'col-logon' },
  { label: 'Path', className: 'col-path' },
] as const;

const HEADER_COLUMNS_RIGHT = [
  { label: '#', className: 'col-num' },
  { label: 'Name', className: 'col-name' },
  { label: 'Description', className: 'col-desc' },
  { label: 'Status', className: 'col-status' },
  { label: 'Startup Type', className: 'col-startup' },
  { label: 'End Type', className: 'col-endtype' },
  { label: 'Log On As', className: 'col-logon' },
  { label: 'Path', className: 'col-path' },
] as const;

function mapStartupType(value: string): string {
  if (!value) return 'Manual';
  const lower = value.toLowerCase();
  if (lower.includes('auto') && lower.includes('del')) return 'Automatic (Delayed Start)';
  if (lower.includes('auto')) return 'Automatic';
  if (lower.includes('disabled')) return 'Disabled';
  return 'Manual';
}

// Create select element with options (reusable)
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

function makeRow(
  s: Service,
  index: number,
  rowNumber: number,
  onStartupChange: (i: number, val: string) => void,
  onEndTypeChange: (i: number, val: string) => void
) {
  const row = el('div', 'row');
  row.draggable = true;
  row.dataset.index = String(index);

  const startup = createSelect('col-startup select', mapStartupType(s.startup_type));
  const endtype = createSelect('col-endtype select', mapStartupType(s.end_type || s.startup_type));

  // Update endtype background based on comparison
  const updateEndTypeHighlight = () => {
    endtype.classList.toggle('different', startup.value !== endtype.value);
  };

  updateEndTypeHighlight();

  startup.onchange = () => {
    onStartupChange(index, startup.value);
    updateEndTypeHighlight();
  };

  endtype.onchange = () => {
    onEndTypeChange(index, endtype.value);
    updateEndTypeHighlight();
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
    el('div', 'col-startup', s.startup_type),
    el('div', 'col-logon', s.log_on_as),
    el('div', 'col-path muted', s.path)
  );
  return row;
}

function renderApp(current: Service[], targets: Service[]) {
  app.innerHTML = '';
  const root = el('div', 'app');
  const toolbar = el('div', 'toolbar');
  const toolbarTitle = el('div', 'toolbar-title', 'Ordem — Service ordering and target startup types');
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

  // Sync column widths from header to data rows for a specific pane
  function syncPaneWidths(headerRow: HTMLElement, paneClass: string) {
    const headerCols = headerRow.querySelectorAll('[class^="col-"], .drag-handle');
    headerCols.forEach((headerCol) => {
      const colClass = (headerCol as HTMLElement).className.split(' ')[0];
      const headerWidth = (headerCol as HTMLElement).style.width || `${(headerCol as HTMLElement).offsetWidth}px`;
      document.querySelectorAll(`.${paneClass} .row .${colClass}`).forEach(cell => {
        (cell as HTMLElement).style.width = headerWidth;
      });
    });
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

        const startX = e.pageX;
        const startWidth = (col as HTMLElement).offsetWidth;
        const colClass = (col as HTMLElement).className.split(' ')[0];
        const selector = `.${paneClass} .row .${colClass}`;
        const cells = document.querySelectorAll(selector);

        const onMouseMove = (e: MouseEvent) => {
          const width = Math.max(50, startWidth + (e.pageX - startX));
          (col as HTMLElement).style.width = `${width}px`;
          cells.forEach(cell => {
            (cell as HTMLElement).style.width = `${width}px`;
          });
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

  // Event delegation for drag-and-drop
  rlist.addEventListener('dragstart', (ev) => {
    const row = (ev.target as HTMLElement).closest('.row') as HTMLElement;
    if (row) ev.dataTransfer!.setData('text/plain', row.dataset.index!);
  });

  rlist.addEventListener('dragover', (ev) => {
    if ((ev.target as HTMLElement).closest('.row')) ev.preventDefault();
  });

  rlist.addEventListener('drop', (ev) => {
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

  const handleStartupChange = (idx: number, val: string) => {
    items[idx].startup_type = val;
    saveTargets(items);
  };

  const handleEndTypeChange = (idx: number, val: string) => {
    items[idx].end_type = val;
    saveTargets(items);
  };

  function rebuildRight() {
    rlist.innerHTML = '';
    items.forEach((s, i) => {
      rlist.appendChild(makeRow(s, i, i + 1, handleStartupChange, handleEndTypeChange));
    });
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

  // Manual Startup Type button
  const manualStartupType = el('button', 'btn btn-reset', 'Manual Startup Type');
  manualStartupType.onclick = async () => {
    items.forEach(s => s.startup_type = 'Manual');
    await saveTargets(items);
    rebuildRight();
  };

  // Reset Target button
  const resetTarget = el('button', 'btn btn-reset', 'Reset Target');
  resetTarget.onclick = async () => {
    if (confirm('Reset targets to match current state? This will overwrite all target configurations.')) {
      items = current.slice().map(s => ({ ...s, end_type: s.startup_type }));
      await saveTargets(items);
      rebuildRight();
    }
  };

  toolbarLeft.append(toggleLeft, toggleRight);
  toolbarRight.append(manualStartupType, resetTarget);
  content.append(leftPane, rightPane);
  root.append(toolbar, content);
  app.appendChild(root);

  // Sync row heights and column widths after DOM is rendered
  syncRowHeights();
  syncInitialWidths();
}

async function start() {
  if (!isWindowsClient()) {
    showUnsupported();
    return;
  }
  try {
    const [current, targets] = await Promise.all([
      fetchJSON<Service[]>('/api/services'),
      fetchJSON<Service[]>('/api/targets'),
    ]);
    // Ensure end_type is initialized if missing
    const normalizedTargets = targets.map(s => ({
      ...s,
      end_type: s.end_type || s.startup_type
    }));
    renderApp(current, normalizedTargets);
  } catch (e) {
    app.innerHTML = `<div style="padding:20px">Error: ${(e as Error).message}</div>`;
    console.error(e);
  }
}

start();
