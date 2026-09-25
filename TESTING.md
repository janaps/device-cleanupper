# Testing the Device CleanUpper

Thank you for testing. The Device CleanUpper releases Windows devices from a
Microsoft 365 tenant, so another tenant can take them over: it removes them
from Intune, from Windows Autopilot and, where needed, from Entra ID.

**Everything starts as a dry run.** Until you switch that off yourself, the tool
only reports what it *would* do and changes nothing in the tenant.

Which version you have is in `VERSION.txt`.

---

## Before you start

**On your PC**

1. Install PowerShell 7 if you do not have it yet:
   `winget install --id Microsoft.PowerShell -e`
2. Before you extract the zip: right-click it → **Properties** → tick
   **Unblock** → OK. Otherwise Windows treats every file as downloaded from the
   internet and keeps asking for permission.
3. Extract it to a local folder, e.g. `C:\Tools\DeviceCleanUpper`.

4. Check `VERSION.txt`, line *Graph*. If it says the Graph module is *not
   included*, install it once:
   `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`
   Otherwise nothing else has to be installed - it is in the `modules` folder.

**Your account** needs the **Intune Administrator** and **Cloud Device
Administrator** roles in the tenant you test in.

**Once per tenant, a Global Administrator has to give consent.** The tool signs
in through Microsoft's own "Microsoft Graph Command Line Tools" app, and its
permissions need admin approval - otherwise you get *"Need admin approval"* at
sign-in. The easiest way: the Global Administrator starts this tool once, ticks
both boxes under **Extra permissions to ask for** on the Setup page, clicks
**Sign in**, and ticks **Consent on behalf of your organization** in the
Microsoft window.

**Test devices.** For the real (not dry run) part, use only devices you can
afford to lose from this tenant - test VMs are ideal. A removed Autopilot
registration can only be put back with the device's hardware hash.

---

## Round 1 - dry run (changes nothing)

Start **`Launch.cmd`** (double-click).

| # | Do | Check |
|---|----|-------|
| 1 | Try **Next** before signing in. | Next is greyed out and says why. |
| 2 | **Setup and sign in**: click **Sign in**. | Your account and tenant are shown in green. |
| 3 | **Page 1**: put 2-5 devices on the list - try the Excel tab *and* the Copy / paste tab. | The devices appear in the list. |
| 4 | Try **Next** before looking them up. | Still blocked, with a reason. |
| 5 | Click **Look up N device(s)**. | Every device shows where it was found (Intune / Autopilot / Entra ID). Recently used devices are flagged red and not ticked. |
| 6 | **Step 2**: run the export. | **Open working folder** → `exports` holds a CSV and a JSON. |
| 7 | **Steps 3 to 7**: tick your devices and run each step. | The button is **blue** and starts with *Simulate:*; the results say *DRY RUN - would ...*; nothing changes in the Intune portal. |
| 8 | Right-click the activity list → **Copy all**, paste into Notepad. | The text is there and the tool keeps running. |

## Round 2 - for real (test devices only)

Untick **Dry run** in the bar at the bottom. The Run button turns **red** and
every step asks for confirmation.

| # | Do | Check |
|---|----|-------|
| 9 | **Step 4 - Remove from Intune.** | The devices are gone from the Intune portal. |
| 10 | **Step 5 - Remove the Autopilot registration.** | Rows show *Deletion pending*. No sync is sent in this step. |
| 11 | **Step 6 - Sync Autopilot and confirm.** | If a registration is still there: a sync is sent and a countdown runs in the activity list (up to 10 minutes). If everything is already gone: *no sync needed*. |
| 12 | During that countdown, click **Cancel** once; then run step 6 again. | Cancel only stops the waiting; the second run picks up where it left off. |
| 13 | **Step 7 - Entra ID** (optional): untick *Skip devices that were Autopilot registered*. Include a device whose Autopilot registration you removed yourself in the Intune portal. | That device's Entra object is deleted. A device still in Autopilot is skipped, with a message saying to run steps 5 and 6. |
| 14 | **Step 8 - Final check.** | The handover report (CSV + text checklist) is in `exports`. |

Anything else you would normally do is welcome too - odd spreadsheets, typos
in serial numbers, a device that is not in the tenant at all.

---

## Where things are

Everything goes to the working folder (default `Documents\DeviceCleanUpper`,
button **Open working folder**):

```
logs\devicecleanupper-<date>.log   everything the tool did, line by line
workingset.json                    the device list and how far each device got
exports\                           the export (step 2) and the handover report (step 8)
```

## What to send back

For each problem, or at the end of the test:

- what you did, what you expected and what happened instead
- `VERSION.txt`
- the log file of that day (`logs\devicecleanupper-<date>.log`)
- `workingset.json`
- a screenshot if something looked wrong

The log contains device names, serial numbers and account names from your
tenant - send it the way you would send any internal document.
