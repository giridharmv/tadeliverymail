# Ranorex TA Delivery Email Generator

A local web application for preparing consistent, Outlook-ready delivery emails for the Ranorex test automation framework. It turns version information, auto-generated delivery links, work-item links, module changes, special notes, resolved bugs, and QPC results into a formatted email with tables and hyperlinks.

## Requirements

- Windows with PowerShell
- A modern browser
- Git credentials for `saturn.tfs.siemens.net` when using TFS fetch actions

## Clone the repository

Clone the project to your local computer:

```powershell
git clone https://code.siemens.com/giridhar.m-v/tadeliverymailgenerator.git
cd tadeliverymailgenerator
```

## Launch the application

1. Double-click `Launch-RanorexDeliveryEmailGenerator.cmd` in the repository folder.
2. The application opens at `http://127.0.0.1:<port>/` in the default browser, where `<port>` is a free port chosen automatically for the current computer.
3. Keep the command window running while using the app. Close the window to stop it.

The launch script enables TFS-backed fetch operations for work items and user details. Opening the HTML directly supports manual entry and email generation, but not TFS fetch.

## Create a delivery email

1. Fill **Version Information**:
	  - **Full Build Number**, **Product Version**
   - **Ranorex Version**, **RTM Build Number**
   - **SIMIT Version**, **Team Number**
   - **Chrome Version**, **Safety Version**
   - Enable **New Ranorex Version** when the migration note is required
2. **Delivery Links**; these are auto-generated.
3. Add items in PBIs, module tables, and resolved bugs.
4. Add project-specific notes in **Special Notes**.
5. Fill **QPC Execution Results** for executed projects.
6. Select **Generate Email**.
7. Review output, then use **Draft a mail in Outlook**.

## Example: add a PBI by ID or URL

1. Open **PBIs (Product Backlog Items)**.
2. Paste the PBI ID or URL in **PBI URL (for hyperlink)**, for example:

   ```text
   https://saturn.tfs.siemens.net/tfs/PA/PNS/_workitems/edit/934886
   ```

3. Enter **Raised By**.
4. Select **Fetch** for that row, or **Fetch All PBIs** for multiple rows.

The app extracts the PBI ID and title, resolves qualifying child modules, and populates relevant module sections. Generated email keeps the PBI ID as a clickable hyperlink.

## Field-by-field input guide

| Section | What to enter |
| --- | --- |
| Version Information | Full Build Number, Product Version, Ranorex Version, RTM Build Number, SIMIT Version, Team Number, Chrome Version, Safety Version, New Ranorex Version |
| Delivery Links | Auto-generated delivery URLs, help-doc URLs, Ranorex installer URL |
| PBIs | PBI ID or URL, title/description, raised by |
| New Group Modules | Task ID, work-item URL, group module name |
| New CPI Modules | Task ID, work-item URL, module name, project area |
| Adapted Modules | Task ID, work-item URL, adapted module name |
| Resolved Bugs | Fetch bugs with or without the Ranorex_RTM tag, or enter bug ID, URL, description manually |
| Special Notes | Select project note or **Custom Note...** and edit the special-note text box |
| QPC Execution Results | Enter Light/Dark results as `passed/total` (example `283/283`) |

## Special Notes behavior

- Selecting a predefined project note shows its editable text box.
- Selecting **Custom Note...** opens a free-form text box for delivery-specific messaging.
- Multiple notes can be added and appear in the generated Important Notes section.

## Fetch behavior

- PBIs can be fetched using either a PBI ID or a PBI URL.
- Delivery links are auto-generated.
- Bugs can be fetched with the Ranorex_RTM tag or without a tag, and bug details can also be entered manually.

## Drafts and utilities

- **Save Draft** stores up to 20 drafts in browser local storage.
- Restore saved drafts from the **History** tab.
- **Clear Form** resets all current entries after confirmation.
- Theme toggle switches between light and dark mode.

## Operational notes

- Do not enter credentials or tokens in form fields.
- TFS fetch requires network access to Siemens TFS and valid local credentials.
- Always review generated content before sending.
