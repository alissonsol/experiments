document.addEventListener("DOMContentLoaded", async () => {
    const params = new URLSearchParams(window.location.search);
    const menu = params.get('menu') || 'default';
    const lang = params.get('lang') || 'en'; // TODO: Preserve language selection across pages
    const menuFileName = "./menu." + lang + "/" + menu + ".txt";

    try {
        // Fetch the data file
        const response = await fetch(menuFileName);
        let data;
        if (response.ok) {
            data = await response.text();
        } else {
            // Default to 'menu.en/default.txt' in case of error
            const defaultMenu = await fetch("./menu.en/default.txt");
            if (!defaultMenu.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            data = await defaultMenu.text();
        }
        const lines = data.split('\n').filter(line => line.trim() !== '');

        // Hide loading indicator
        document.getElementById('loading-indicator').style.display = 'none';

        if (lines.length < 4) {
            // We check for at least 4 lines to ensure basic structure is present.
            throw new Error("Data file has an invalid structure. At least 4 lines are required.");
        }

        // Parse the data and update the page
        const pageTitle = decodeURIComponent(lines[0].trim());
        const menuHeader = decodeURIComponent(lines[1].trim());
        const menuSubheader = decodeURIComponent(lines[2].trim());
        const menuItems = lines.slice(3);

        document.title = pageTitle;
        document.getElementById('menu-header').innerHTML = menuHeader;
        document.getElementById('menu-subheader').innerHTML = menuSubheader;

        const menuContainer = document.getElementById('menu-container');

        // Detect touch/mobile devices (coarse pointer OR common UA substrings)
        const isMobile = (typeof navigator !== 'undefined' && /Mobi|Android|iPhone|iPad|iPod|Opera Mini|IEMobile/i.test(navigator.userAgent))
            || (window.matchMedia && window.matchMedia('(pointer:coarse)').matches);

        menuItems.forEach(itemLine => {
            // Expect: iconSource, menuText, menuExplanation, destinationUrl
            const parts = itemLine.split(',').map(s => s.trim());
            const [iconSource, menuText, menuExplanation, destinationUrl] = parts;
            if (iconSource && menuText && destinationUrl) {
                // Create a wrapper so we can safely place additional controls (toggle button, description)
                const itemWrapper = document.createElement('div');
                itemWrapper.className = 'menu-item-wrapper';

                const link = document.createElement('a');
                link.href = destinationUrl;
                // The following class change makes the icon and text appear on a single line
                link.className = "menu-item-link";

                const icon = document.createElement('span');
                icon.innerHTML = iconSource;

                const text = document.createElement('span');
                text.innerText = menuText;
                // The text size is reduced for a more compact look
                text.className = "menu-text";

                link.appendChild(icon);
                link.appendChild(text);

                // If there's an explanation, wire it up accessibly for both screen readers and mobile users.
                if (menuExplanation && menuExplanation.length) {
                    const descId = `menu-desc-${Math.random().toString(36).slice(2,9)}`;

                    // Always create a (visually hidden) description for screen readers and reference it
                    const sr = document.createElement('span');
                    sr.id = descId;
                    sr.className = 'visually-hidden menu-explanation-sr';
                    // Offscreen styling to keep it accessible to assistive tech
                    sr.style.position = 'absolute';
                    sr.style.left = '-9999px';
                    sr.style.width = '1px';
                    sr.style.height = '1px';
                    sr.style.overflow = 'hidden';
                    sr.innerText = menuExplanation;
                    itemWrapper.appendChild(sr);
                    link.setAttribute('aria-describedby', descId);

                    if (!isMobile) {
                        // Desktop: keep the title tooltip for sighted mouse users
                        link.title = menuExplanation;
                    } else {
                        // Mobile / touch: provide a visible toggle so touch users can reveal the explanation
                        const infoBtn = document.createElement('button');
                        infoBtn.type = 'button';
                        infoBtn.className = 'explain-toggle';
                        infoBtn.setAttribute('aria-controls', descId);
                        infoBtn.setAttribute('aria-expanded', 'false');
                        infoBtn.setAttribute('aria-label', 'Show item explanation');
                        infoBtn.innerText = 'ℹ️';
                        // Style the button minimally so it doesn't break layout; projects should add CSS
                        infoBtn.style.marginLeft = '8px';
                        infoBtn.style.fontSize = '0.9em';
                        infoBtn.style.lineHeight = '1';

                        // Visible explanation element that will be toggled for touch users
                        const visibleDesc = document.createElement('div');
                        visibleDesc.id = descId + '-visible';
                        visibleDesc.className = 'menu-explanation-visible';
                        visibleDesc.style.display = 'none';
                        visibleDesc.style.fontSize = '0.9em';
                        visibleDesc.style.marginTop = '4px';
                        visibleDesc.innerText = menuExplanation;

                        infoBtn.addEventListener('click', () => {
                            const expanded = infoBtn.getAttribute('aria-expanded') === 'true';
                            infoBtn.setAttribute('aria-expanded', String(!expanded));
                            infoBtn.setAttribute('aria-label', expanded ? 'Show item explanation' : 'Hide item explanation');
                            visibleDesc.style.display = expanded ? 'none' : 'block';
                        });

                        // Append link, button and visible description inside the wrapper
                        itemWrapper.appendChild(link);
                        itemWrapper.appendChild(infoBtn);
                        itemWrapper.appendChild(visibleDesc);
                        menuContainer.appendChild(itemWrapper);
                        return;
                    }
                }

                // Default append (no explanation or desktop path already added link)
                itemWrapper.appendChild(link);
                menuContainer.appendChild(itemWrapper);
            }
        });

    } catch (error) {
        console.error("Failed to load or parse data file:", error);
        document.getElementById('loading-indicator').innerHTML = `<p class='text-red-500'>Error: Failed to load menu data from '${menuFileName}'. Check the file name and structure.</p>`;
    }
});
