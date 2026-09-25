# Security policy

## Supported versions

Only the latest release gets fixes. Check which one you have in `VERSION.txt`
and compare it with the
[latest release](https://github.com/janaps/device-cleanupper/releases/latest).

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Report it privately
through GitHub instead: the repository's **Security** tab → **Report a
vulnerability**. Only the maintainer sees that report.

Please include what an attacker could do, the steps to reproduce it, and the
version. Leave real tenant data out - device names, serial numbers, account
names and BitLocker keys are never needed to explain the problem.

You can expect a first reply within a week. This is a spare-time project, so
a fix can take longer; you will hear how it is going.

## What counts

Anything that makes the tool do more than the signed-in administrator asked
for, or expose more than it should, for example:

- a destructive call (wipe, delete) sent during a dry run, or for a device that
  was not selected
- tenant data or tokens written somewhere other than the working folder or
  the log
- BitLocker recovery keys ending up anywhere other than the export the user
  asked for

What the Microsoft Graph permissions themselves allow is Microsoft's design,
not a vulnerability in this tool.
