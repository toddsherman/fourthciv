# Opening Fourth Civ at login

Starting with alpha.7, the first normal launch of the installed app enables **Open at login**. This applies to new installs and upgrades from versions without this feature. Use **Your contribution → Open at login** or macOS Login Items to change it. Later launches and updates respect that choice. Starting the app does not unpause participation or enable disabled internet sharing.

Fourth Civ uses Apple's [SMAppService main-app registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()). macOS launches the app after this user logs in; it does not run a system daemon before login. When macOS reports [requiresApproval](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval), the app shows that automatic startup is off and links to Login Items. It does not repeatedly request registration or bypass the system choice.

The operating system is the source of the current enabled state. A version-independent local preference remembers that the initial default was attempted. A failed registration is shown in Your contribution and can be retried with its toggle. No custom launch agent, privileged helper, or recurring shell task is installed.

Registration is available only for release apps opened from `/Applications` or the user's `~/Applications` folder. Opening the disk image, a demo/development build, or an isolated session with a custom data directory or port never registers a login item or consumes the initial default. Hosts should drag the app into Applications and open it once.

Quitting stops the current session and leaves Open at login unchanged. Turning Open at login off prevents future automatic starts. Deleting the application removes the executable; already shared public conversations may remain on other hosts.
