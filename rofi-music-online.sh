#!/usr/bin/env bash

DOWNLOAD_DIR="${XDG_MUSIC_DIR:-$HOME/Music}/rofi-online"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/rofi-music-online.state"
HISTORY_FILE="${XDG_RUNTIME_DIR:-/tmp}/rofi-music-online.history"
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/rofi-music-online.pid"
SOCKET="/tmp/mpv-online.sock"
MAX_RESULTS=12
MAX_HISTORY=30

mkdir -p "$DOWNLOAD_DIR"

save_state() {
    printf "%s\n%s\n%s\n" "$1" "$2" "$3" > "$STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        STATE_MODE=$(sed -n '1p' "$STATE_FILE")
        STATE_QUERY=$(sed -n '2p' "$STATE_FILE")
        STATE_URL=$(sed -n '3p' "$STATE_FILE")
    else
        STATE_MODE="main"
        STATE_QUERY=""
        STATE_URL=""
    fi
}

history_add() {
    local entry="$1"
    [[ -z "$entry" ]] && return
    local tmp
    tmp=$(mktemp)
    grep -vxF "$entry" "$HISTORY_FILE" 2>/dev/null > "$tmp" || true
    { printf '%s\n' "$entry"; cat "$tmp"; } > "$HISTORY_FILE"
    head -n "$MAX_HISTORY" "$HISTORY_FILE" > "$tmp"
    mv "$tmp" "$HISTORY_FILE"
}

history_list() {
    [[ -f "$HISTORY_FILE" ]] && cat "$HISTORY_FILE" || true
}

mpv_cmd() {
    [[ -S "$SOCKET" ]] || return 1
    printf '%s\n' "$1" | socat - UNIX-CONNECT:"$SOCKET" &>/dev/null
}

mpv_get() {
    [[ -S "$SOCKET" ]] || return 1
    printf '%s\n' "$1" | socat -t 1 - UNIX-CONNECT:"$SOCKET" 2>/dev/null
}

is_playing() {
    [[ -S "$SOCKET" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

get_current_track() {
    local raw
    raw=$(mpv_get '{"command":["get_property","media-title"]}')
    printf '%s' "$raw" | grep -o '"data":"[^"]*"' | head -1 | sed 's/"data":"//;s/"//'
}

is_paused() {
    local raw
    raw=$(mpv_get '{"command":["get_property","pause"]}')
    printf '%s' "$raw" | grep -q '"data":true'
}

stop_music() {
    mpv_cmd '{"command":["quit"]}' 2>/dev/null
    sleep 0.2
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$PID_FILE" "$SOCKET"
}

stream_url() {
    local url="$1"
    local title="$2"
    stop_music
    mpv \
        --no-video \
        --input-ipc-server="$SOCKET" \
        --script-opts=ytdl_hook-ytdl_path=yt-dlp \
        --ytdl-format="bestaudio/best" \
        --really-quiet \
        --msg-level=all=no \
        --title="$title" \
        "$url" \
        &>/dev/null &
    echo $! > "$PID_FILE"
    save_state "playing" "$title" "$url"
}

search_yt() {
    local query="$1"
    local source="$2"
    yt-dlp \
        --no-warnings \
        --quiet \
        --flat-playlist \
        --print "%(webpage_url)s|%(duration_string)s|%(title)s" \
        "${source}${MAX_RESULTS}:${query}" \
        2>/dev/null
}

url_info() {
    local url="$1"
    yt-dlp \
        --no-warnings \
        --quiet \
        --print "%(webpage_url)s|%(duration_string)s|%(title)s" \
        --no-playlist \
        "$url" \
        2>/dev/null | head -1
}

download_track() {
    local url="$1"
    local title="$2"
    local logfile
    logfile=$(mktemp)

    yt-dlp \
        --no-warnings \
        --extract-audio \
        --audio-format mp3 \
        --audio-quality 0 \
        --output "$DOWNLOAD_DIR/%(title)s.%(ext)s" \
        "$url" > "$logfile" 2>&1

    local status=$?
    rm -f "$logfile"

    if [[ $status -eq 0 ]]; then
        printf 'Pobrano: %s\nOK\n' "$title" | rofi -dmenu \
            -p "✔ Downloaded to ~/Music/rofi-online/" \
            -theme-str 'window { width: 55%; } listview { lines: 3; }' \
            -i &>/dev/null
    else
        printf 'Blad pobierania.\nWróć\n' | rofi -dmenu \
            -p "✖ Downloading error" \
            -theme-str 'window { width: 50%; } listview { lines: 3; }' \
            -i &>/dev/null
    fi
}

rofi_show() {
    local prompt="$1"
    shift
    printf '%s\n' "$@" | rofi -dmenu \
        -p "$prompt" \
        -theme-str 'window { width: 65%; } listview { lines: 14; }' \
        -i
}

results_menu() {
    local query="$1"
    local source_name="$2"
    local -n _results=$3

    local keys=()
    local labels=()

    for line in "${_results[@]}"; do
        local url dur title
        url=$(printf '%s' "$line" | cut -d'|' -f1)
        dur=$(printf '%s' "$line" | cut -d'|' -f2)
        title=$(printf '%s' "$line" | cut -d'|' -f3-)
        keys+=("$url")
        labels+=(" [$dur]  $title")
    done

    keys+=("__sep__")
    labels+=("───────────────────")
    keys+=("__back__")
    labels+=("⬅  New search")
    keys+=("__main__")
    labels+=("⌂  Main Menu")

    local prompt_text="$source_name: $query"
    if is_playing; then
        local cur
        cur=$(get_current_track)
        prompt_text="[♪ $cur]  $source_name: $query"
    fi

    while true; do
        local choice
        choice=$(printf '%s\n' "${labels[@]}" | rofi -dmenu \
            -p "$prompt_text" \
            -theme-str 'window { width: 70%; } listview { lines: 14; }' \
            -i)

        [[ $? -ne 0 ]] && { save_state "search" "$query" ""; exit 0; }

        local idx=0
        local found_key=""
        for i in "${!labels[@]}"; do
            if [[ "${labels[$i]}" == "$choice" ]]; then
                found_key="${keys[$i]}"
                break
            fi
        done

        case "$found_key" in
            __sep__)    continue ;;
            __back__)   search_menu; return ;;
            __main__)   main_menu; return ;;
            "")         continue ;;
            *)
                local track_title=""
                for i in "${!keys[@]}"; do
                    if [[ "${keys[$i]}" == "$found_key" ]]; then
                        track_title="${labels[$i]}"
                        track_title="${track_title#* ]  }"
                        break
                    fi
                done
                stream_url "$found_key" "$track_title"
                playing_menu "$query" "$found_key" "$track_title"
                ;;
        esac
    done
}

search_menu() {
    while true; do
        local keys=()
        local labels=()

        keys+=("__yt__");    labels+=(" YouTube")
        keys+=("__sc__");    labels+=(" SoundCloud")
        keys+=("__url__");   labels+=(" Paste the link (URL)")
        keys+=("__sep__");   labels+=("───────────────────")

        local hist_items=()
        while IFS= read -r h; do
            [[ -n "$h" ]] && hist_items+=("$h")
        done < <(history_list)

        if [[ ${#hist_items[@]} -gt 0 ]]; then
            keys+=("__hsep__"); labels+=(" History:")
            for h in "${hist_items[@]}"; do
                keys+=("hist:$h")
                labels+=(" ⟳  $h")
            done
            keys+=("__sep2__"); labels+=("───────────────────")
        fi

        keys+=("__main__"); labels+=("⌂  Menu główne")

        local choice
        choice=$(printf '%s\n' "${labels[@]}" | rofi -dmenu \
            -p "🔍 Search for music" \
            -theme-str 'window { width: 60%; } listview { lines: 14; }' \
            -i)

        [[ $? -ne 0 ]] && { save_state "search" "" ""; exit 0; }

        local found_key=""
        for i in "${!labels[@]}"; do
            if [[ "${labels[$i]}" == "$choice" ]]; then
                found_key="${keys[$i]}"
                break
            fi
        done

        case "$found_key" in
            __sep__|__sep2__|__hsep__) continue ;;
            __main__) main_menu; return ;;

            __yt__|__sc__|__url__)
                local platform_label=""
                local source=""
                case "$found_key" in
                    __yt__)  platform_label="YouTube";     source="ytsearch" ;;
                    __sc__)  platform_label="SoundCloud";  source="scsearch" ;;
                    __url__) platform_label="URL";         source="url" ;;
                esac

                local query
                query=$(rofi -dmenu \
                    -p "🔍 $platform_label — Enter a title or URL etc." \
                    -theme-str 'window { width: 60%; } listview { lines: 0; }' \
                    < /dev/null)

                [[ -z "$query" ]] && continue

                history_add "$query"
                save_state "search" "$query" ""

                local raw_results=()
                if [[ "$source" == "url" ]] || printf '%s' "$query" | grep -qE '^https?://'; then
                    local info
                    info=$(url_info "$query")
                    [[ -n "$info" ]] && raw_results+=("$info")
                else
                    while IFS= read -r line; do
                        [[ -n "$line" ]] && raw_results+=("$line")
                    done < <(search_yt "$query" "$source")
                fi

                if [[ ${#raw_results[@]} -eq 0 ]]; then
                    printf 'No search results for: %s\nTry again\n' "$query" \
                        | rofi -dmenu \
                            -p "✖ No search results" \
                            -theme-str 'window { width: 50%; } listview { lines: 3; }' \
                            -i &>/dev/null
                    continue
                fi

                results_menu "$query" "$platform_label" raw_results
                return
                ;;

            hist:*)
                local hquery="${found_key#hist:}"
                local plat
                plat=$(printf 'YouTube\nSoundCloud\nURL\n' | rofi -dmenu \
                    -p "🔍 $hquery — Choose the platform" \
                    -theme-str 'window { width: 50%; } listview { lines: 4; }' \
                    -i)
                [[ -z "$plat" ]] && continue

                local source2=""
                case "$plat" in
                    YouTube)    source2="ytsearch" ;;
                    SoundCloud) source2="scsearch" ;;
                    URL)        source2="url" ;;
                esac

                local raw2=()
                if [[ "$source2" == "url" ]] || printf '%s' "$hquery" | grep -qE '^https?://'; then
                    local info2
                    info2=$(url_info "$hquery")
                    [[ -n "$info2" ]] && raw2+=("$info2")
                else
                    while IFS= read -r line; do
                        [[ -n "$line" ]] && raw2+=("$line")
                    done < <(search_yt "$hquery" "$source2")
                fi

                if [[ ${#raw2[@]} -eq 0 ]]; then
                    printf 'No search results.\nBack\n' | rofi -dmenu \
                        -p "✖ No search results" \
                        -theme-str 'window { width: 50%; } listview { lines: 3; }' \
                        -i &>/dev/null
                    continue
                fi

                results_menu "$hquery" "$plat" raw2
                return
                ;;
        esac
    done
}

playing_menu() {
    local query="${1:-}"
    local url="${2:-}"
    local track_title="${3:-}"

    while true; do
        local cur="(Nothing playing)"
        local pause_label="⏸  Pause"

        if is_playing; then
            cur=$(get_current_track)
            [[ -z "$cur" ]] && cur="$track_title"
            is_paused && pause_label="▶  Resume"
        fi

        local keys=(NOOP SEP PAUSE DOWNLOAD STOP SEARCH MAIN QUIT)
        local labels=(
            "♪  $cur"
            "───────────────────"
            "$pause_label"
            "⬇  Download MP3  →  ~/Music/rofi-online/"
            "⏹  Stop"
            "🔍  New Search"
            "⌂  Main Menu"
            "✖  Quit"
        )

        save_state "playing" "$query" "$url"

        local choice
        choice=$(printf '%s\n' "${labels[@]}" | rofi -dmenu \
            -p "♫ online" \
            -theme-str 'window { width: 58%; } listview { lines: 10; }' \
            -i)

        [[ $? -ne 0 ]] && { save_state "playing" "$query" "$url"; exit 0; }

        local cmd=""
        for i in "${!labels[@]}"; do
            if [[ "${labels[$i]}" == "$choice" ]]; then
                cmd="${keys[$i]}"
                break
            fi
        done

        case "$cmd" in
            NOOP|SEP) ;;
            PAUSE)
                if is_paused; then
                    mpv_cmd '{"command":["set_property","pause",false]}'
                else
                    mpv_cmd '{"command":["set_property","pause",true]}'
                fi
                ;;
            DOWNLOAD)
                [[ -n "$url" ]] && download_track "$url" "${track_title:-$cur}"
                ;;
            STOP)
                stop_music
                main_menu
                return
                ;;
            SEARCH)
                search_menu
                return
                ;;
            MAIN)
                main_menu
                return
                ;;
            QUIT)
                exit 0
                ;;
        esac
    done
}

main_menu() {
    while true; do
        local keys=()
        local labels=()

        if is_playing; then
            local cur
            cur=$(get_current_track)
            keys+=("GOTO_PLAYING"); labels+=("♪  $cur")
            keys+=("SEP0");         labels+=("───────────────────")
        fi

        keys+=("SEARCH");  labels+=("🔍  Search  YouTube / SoundCloud / URL")
        keys+=("LOCAL");   labels+=("📁  Downloads  →  ~/Music/rofi-online/")
        keys+=("HISTORY"); labels+=("⟳  Search history")

        if is_playing; then
            keys+=("SEP1");  labels+=("───────────────────")
            keys+=("PAUSE"); labels+=("⏸  Pause / Resume")
            keys+=("STOP");  labels+=("⏹  Stop")
        fi

        keys+=("SEP2"); labels+=("───────────────────")
        keys+=("QUIT"); labels+=("✖  Quit")

        save_state "main" "" ""

        local choice
        choice=$(printf '%s\n' "${labels[@]}" | rofi -dmenu \
            -p "rofi-music-online" \
            -theme-str 'window { width: 60%; } listview { lines: 12; }' \
            -i)

        [[ $? -ne 0 ]] && { save_state "main" "" ""; exit 0; }

        local cmd=""
        for i in "${!labels[@]}"; do
            if [[ "${labels[$i]}" == "$choice" ]]; then
                cmd="${keys[$i]}"
                break
            fi
        done

        case "$cmd" in
            GOTO_PLAYING)
                playing_menu "$STATE_QUERY" "$STATE_URL" "$(get_current_track)"
                ;;
            SEP0|SEP1|SEP2) ;;
            SEARCH)
                search_menu
                ;;
            LOCAL)
                local files=()
                while IFS= read -r f; do
                    files+=("$(basename "$f")")
                done < <(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \
                    | grep -iE '\.(mp3|flac|ogg|m4a|opus|wav)$' | sort)

                if [[ ${#files[@]} -eq 0 ]]; then
                    printf 'No downloaded files.\nBack\n' | rofi -dmenu \
                        -p "📁 Downloads — Empty folder" \
                        -theme-str 'window { width: 50%; } listview { lines: 3; }' \
                        -i &>/dev/null
                else
                    local sel
                    sel=$(printf '%s\n' "${files[@]}" | rofi -dmenu \
                        -p "📁 Downloads" \
                        -theme-str 'window { width: 60%; } listview { lines: 14; }' \
                        -i)
                    if [[ -n "$sel" ]]; then
                        local fpath="$DOWNLOAD_DIR/$sel"
                        if [[ -f "$fpath" ]]; then
                            stop_music
                            mpv --no-video \
                                --input-ipc-server="$SOCKET" \
                                --really-quiet \
                                --msg-level=all=no \
                                "$fpath" &>/dev/null &
                            echo $! > "$PID_FILE"
                            save_state "playing" "$sel" "$fpath"
                            playing_menu "$sel" "$fpath" "$sel"
                        fi
                    fi
                fi
                ;;
            HISTORY)
                local hist_items=()
                while IFS= read -r h; do
                    [[ -n "$h" ]] && hist_items+=("$h")
                done < <(history_list)

                if [[ ${#hist_items[@]} -eq 0 ]]; then
                    printf 'History is empty.\nBack\n' | rofi -dmenu \
                        -p "⟳ History" \
                        -theme-str 'window { width: 50%; } listview { lines: 3; }' \
                        -i &>/dev/null
                else
                    local hsel
                    hsel=$(printf '%s\n' "${hist_items[@]}" | rofi -dmenu \
                        -p "⟳ History — choose to go back" \
                        -theme-str 'window { width: 60%; } listview { lines: 14; }' \
                        -i)
                    if [[ -n "$hsel" ]]; then
                        local plat2
                        plat2=$(printf 'YouTube\nSoundCloud\nURL\n' | rofi -dmenu \
                            -p "🔍 $hsel — platforma" \
                            -theme-str 'window { width: 50%; } listview { lines: 4; }' \
                            -i)
                        if [[ -n "$plat2" ]]; then
                            local src2=""
                            case "$plat2" in
                                YouTube)    src2="ytsearch" ;;
                                SoundCloud) src2="scsearch" ;;
                                URL)        src2="url" ;;
                            esac
                            local raw3=()
                            if [[ "$src2" == "url" ]] || printf '%s' "$hsel" | grep -qE '^https?://'; then
                                local i3
                                i3=$(url_info "$hsel")
                                [[ -n "$i3" ]] && raw3+=("$i3")
                            else
                                while IFS= read -r line; do
                                    [[ -n "$line" ]] && raw3+=("$line")
                                done < <(search_yt "$hsel" "$src2")
                            fi
                            if [[ ${#raw3[@]} -gt 0 ]]; then
                                results_menu "$hsel" "$plat2" raw3
                            fi
                        fi
                    fi
                fi
                ;;
            PAUSE)
                if is_paused; then
                    mpv_cmd '{"command":["set_property","pause",false]}'
                else
                    mpv_cmd '{"command":["set_property","pause",true]}'
                fi
                ;;
            STOP)
                stop_music
                ;;
            QUIT)
                exit 0
                ;;
        esac
    done
}

main() {
    local missing=()
    for dep in rofi mpv yt-dlp socat; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf 'Brakuje: %s\nWyjscie\n' "${missing[*]}" | rofi -dmenu \
            -p "✖ missing dependencies" \
            -theme-str 'window { width: 50%; } listview { lines: 4; }' \
            -i &>/dev/null
        exit 1
    fi

    load_state

    case "$STATE_MODE" in
        playing)
            if is_playing; then
                playing_menu "$STATE_QUERY" "$STATE_URL" ""
            else
                main_menu
            fi
            ;;
        *)
            main_menu
            ;;
    esac
}

main
