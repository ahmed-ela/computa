# U01 workspace and macOS worker

## First-boot keyboard check

Before entering a saved password in Tart's Setup Assistant, type a harmless mixed-case sample such as `aB7-c` in the optional hint field and compare it character for character. Clear the hint afterward. On the M4 test host, desktop automation sent lowercase letters for both typed capitals and a simulated Shift combination. The password and confirmation can match each other even when both differ from the saved login.

If the sample changes, switch to a native keyboard input method that forwards modifier presses to the guest and rerun the sample. Use the saved credential only after the sample matches. Keep the credential in Apple Passwords and out of screenshots, logs, command arguments, hints, and Git. This is a guest input check to repeat after changing Tart or the desktop automation tool.
