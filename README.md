# rofi-music-online
online version of rofi-music
it connects to youtube/souncloud etc.
# Features:
-no ads
-download option
-works in the background
-searching by title/author
# Needed to work
* yt-dlp
* socat 
* mpv
* rofi

# How to set it up
```bash
git clone https://github.com/KamiruKun/rofi-music-online.git
```
```bash
cd rofi-music-online
```
```bash
chmod +x rofi-music-online.sh
```
```bash
./rofi-music-online.sh
```
it is recommended to bind it to a hotkey for example in hyprland config
for example
```bash
bind = $mainMod, X, exec, $HOME/rofi-music-online/rofi-music-online.sh
```
