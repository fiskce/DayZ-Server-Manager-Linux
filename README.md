[1] Attention! make sure your steam account you are using owns the game or else the mod installation part will fail.
[2] Attention! in some cases the steamcmd wont install the mpmission scripts. if this happens create the "mpmissions" folder and download the mission scripts from [DayZ Central Economy](https://github.com/BohemiaInteractive/DayZ-Central-Economy)

# DayZ Server Manager for Linux Server Instances

![](https://edge-prodberiffagroup.b-cdn.net/web/dayzservermanagerheadlinegifsmall-revisedyellow.gif)

DayZ Server Manager for Linux is a comprehensive and user-friendly script designed to automate server installation, updates, backups, and monitoring. It simplifies the management process, ensuring a seamless and efficient server experience. With automated restarts, mod management, and easy setup, it is a valuable tool for any DayZ server administrator. Try it today and enhance your server operations effortlessly!

## Introduction

DayZ Server Manager for Linux is a custom script designed to simplify the management of DayZ servers on Linux-based systems. It serves as an alternative to the Linux version of Omega Manager.

This script automates key server management tasks, including installation, updates, backups, and monitoring, ensuring a seamless experience for server administrators.

## Disclaimer

Use this [script](https://github.com/fiskce/DayZ-Server-Manager-Linux) at your own risk. You are free to copy, modify, or fork the script as needed, but please retain the original credits at the top of the script. Your support is greatly appreciated.

## Features

- **Automated Installation**: Installs SteamCMD and the DayZ Server with minimal user input.
- **Auto Updates**: Ensures that the server and mods are up-to-date with every restart.
- **Backup System**: Automatically backs up Profile and Mission folders at each startup/restart.
- **Automated Server Management**: Uses Crontab to handle server start, stop, and restart operations.
- **User-Friendly Setup**: Simple configuration process for quick deployment.

## Installation & First Run

To get started, follow these steps:

1. Download the latest version of [dayzserver.sh](https://raw.githubusercontent.com/fiskce/DayZ-Server-Manager-Linux/refs/heads/main/dayzserver.sh) to the root directory of your DayZ server home drive.
2. Grant execution permissions:
   ```sh
   chmod +x dayzserver.sh
   ```
3. Execute the script:
   ```sh
   ./dayzserver.sh
   ```
4. Allow the script to complete its initial setup and follow the on-screen instructions.
5. Configure the **config.ini** file according to your requirements:
   - Set your **steamlogin** credentials.
   - Configure the **port** settings.
   - Add required **@modNames** to the launch parameters.
6. Populate the **workshop.cfg** file with the Mod IDs:
   - List each Mod ID on a separate line.
   - The script will automatically append mod names.
   - Optionally, include the mod name manually in the format: `123456 ModName`
7. Edit the `serverfiles/battleye/beserver_x64*.cfg` file:
   - Set your RCon password and port.
   - Ensure RCon and Game Server ports are not the same (defaults: RCon `2305`, Game Server `2302`).
8. Modify the `serverfiles/serverDZ.cfg` file:
   - Set your server **hostname** and other necessary parameters.
   - Ensure `steamQueryPort` is specified, e.g., `steamQueryPort = 27016;`
9. Run the script again to start your server. Your DayZ server should be online within minutes.

## Mod Management via workshop.cfg

Editing the `workshop.cfg` file is straightforward:

- Add each workshop mod ID on a separate line.
- Run the command:
  ```sh
  ./dayzserver.sh workshop
  ```
  - This will check for updates and append mod names automatically.
- Enable optional Discord notifications for mod updates by adding your Discord webhook URL in **config.ini**.
- Mod timestamps are stored in `mod_timestamps.json` (do not modify this file manually).
- Manually specify mods in the `workshop=""` setting in **config.ini**:
  - Mods must be listed in the correct order for proper functionality.
  - The script ensures all mod folder names are in lowercase.

## Automated Restarts & Updates

To automate server maintenance, add the following Cron jobs to your server user's Crontab:

```sh
@reboot /home/dayz/dayzserver.sh start > /dev/null 2>&1
*/1 * * * * /home/dayz/dayzserver.sh monitor > /dev/null 2>&1
# */30 * * * * /home/dayz/dayzserver.sh backup > /dev/null 2>&1
```

- **@reboot**: Automatically starts the server when the system reboots.
- ***/1 * * * * monitor**: Checks if the server has crashed or been remotely shut down and restarts it if necessary.
- ***/30 * * * * backup** (optional): Creates periodic backups of `storage` and `profile` folders.
  - Note: The script already performs backups at startup/restart by default.

### Server Restart Recommendations

- Use `messages.xml` in your **missions DB folder** for scheduled restarts.
- Alternatively, services like **CFTools** (free tier available) can be used for restart scheduling.
- The `monitor` cron job will restart the server only if:
  - A **RCon** or **messages.xml** shutdown command was issued.
  - The server crashed unexpectedly.
- Running `./dayzserver stop` manually will shut down the server and prevent `monitor` from restarting it.

## Contribution & Support

We encourage contributions, feedback, and suggestions! Feel free to fork the project, submit pull requests, or report issues on GitHub.

If you find this script useful, please consider keeping the credits intact and sharing your experience with the community.

---

With this script, managing your DayZ Linux server is more streamlined, automated, and efficient than ever before. Happy gaming!

