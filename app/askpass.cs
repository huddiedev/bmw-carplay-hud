// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Password helper for Windows' built-in ssh.exe (SSH_ASKPASS). The wizard compiles this file on your own PC the
// first time it runs (Windows PowerShell's Add-Type, no download), so you type the head-unit password once per session.
//
// What it does: ssh starts it with the prompt text as the first argument. It prints the password the wizard put in
// the CPHUD_PW environment variable of the step it is running, and nothing else. It refuses every other question
// (for example a host-key yes/no question), so ssh stops instead of guessing. It never writes anything to disk.
using System;

public static class CphudAskPass
{
    public static int Main(string[] args)
    {
        string prompt = args.Length > 0 ? args[0] : "";
        if (prompt.IndexOf("yes/no", StringComparison.OrdinalIgnoreCase) >= 0 ||
            prompt.IndexOf("fingerprint", StringComparison.OrdinalIgnoreCase) >= 0 ||
            prompt.IndexOf("passphrase", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return 1;
        }
        string pw = Environment.GetEnvironmentVariable("CPHUD_PW");
        if (string.IsNullOrEmpty(pw))
        {
            return 1;
        }
        Console.Out.Write(pw);
        Console.Out.Write("\n");
        Console.Out.Flush();
        return 0;
    }
}
