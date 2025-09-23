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

        menuItems.forEach(itemLine => {
            const [iconSource, menuText, destinationUrl] = itemLine.split(',').map(s => s.trim());
            if (iconSource && menuText && destinationUrl) {
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
                menuContainer.appendChild(link);
            }
        });

    } catch (error) {
        console.error("Failed to load or parse data file:", error);
        document.getElementById('loading-indicator').innerHTML = `<p class='text-red-500'>Error: Failed to load menu data from '${menuFileName}'. Check the file name and structure.</p>`;
    }
});
