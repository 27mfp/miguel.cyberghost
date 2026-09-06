#!/usr/bin/env python3
"""Run vendor setup in a terminal, correcting its misleading [Y/n] defaults.

Only the two known confirmation prompts are adjusted. Account credentials and
sudo authentication remain with the vendor and sudo, on a real terminal. No
input/output transcript is recorded and no credentials enter command arguments.
"""

import os
import pty
import sys


class ConfirmationDefaults:
    PROMPTS = (
        b"Do you want to override the original configuration file? [Y/n]:",
        b"Do you want to change the credentials for the CyberGhost account? [Y/n]:",
    )

    def __init__(self):
        self.output_tail = b""
        self.confirmation = False
        self.answer = bytearray()

    def observe_output(self, data):
        self.output_tail += data
        for prompt in self.PROMPTS:
            if prompt in self.output_tail:
                self.output_tail = self.output_tail.split(prompt, 1)[1]
                self.confirmation = True
                self.answer.clear()
        self.output_tail = self.output_tail[-max(map(len, self.PROMPTS)) :]
        return data

    def translate_input(self, data):
        if not self.confirmation:
            return data
        result = bytearray()
        for value in data:
            if self.confirmation and value in (10, 13):
                if not self.answer:
                    result.extend(b"y")
                self.confirmation = False
                self.answer.clear()
            elif self.confirmation and value in (8, 127):
                if self.answer:
                    self.answer.pop()
            elif self.confirmation:
                self.answer.append(value)
            result.append(value)
        return bytes(result)


def exit_code(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


def main():
    if os.geteuid() == 0:
        print("Run this wrapper as your desktop user, without sudo. It invokes sudo itself.", file=sys.stderr)
        return 2
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("Run this setup in a visible interactive terminal.", file=sys.stderr)
        return 2
    for command in ("/usr/bin/sudo", "/usr/bin/cyberghostvpn"):
        if not os.access(command, os.X_OK):
            print(f"Required executable missing: {command}", file=sys.stderr)
            return 2

    print("CyberGhost vendor setup")
    print("At the two [Y/n] confirmations, Enter now means Yes; type n to decline.")
    print("Enter sudo and CyberGhost passwords in this terminal only.")
    print("The vendor stores account credentials in its private configuration.")
    print("Preserve legacy native credentials before allowing that file to be overwritten.\n", flush=True)
    defaults = ConfirmationDefaults()

    def read_output(fd):
        return defaults.observe_output(os.read(fd, 1024))

    def read_input(fd):
        return defaults.translate_input(os.read(fd, 1024))

    # pty.spawn forwards the terminal directly and restores its settings on exit.
    # No shell, password argument, log file or authentication bypass is involved.
    status = pty.spawn(
        ["/usr/bin/sudo", "--", "/usr/bin/cyberghostvpn", "--setup"],
        master_read=read_output,
        stdin_read=read_input,
    )
    return exit_code(status)


if __name__ == "__main__":
    sys.exit(main())
