# Menu Server

Copyright (c) 2025-2026 by Alisson Sol.

A simple menu server

## WebServer

Ensure the PowerShell execution policy allows scripts to run.
You might need to run: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

The served content is in the `content` folder.
Start by running `WebServer.ps1` from an administrator PowerShell prompt.

## Content

Page `index.html` serves menus from the folder (surprise!) `menus`.

Except when the `lang` parameter is passed. In that case, it seeks for menus in the folder `menus.[lang]`.