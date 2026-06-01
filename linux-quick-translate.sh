#!/bin/bash

# ===== DeepSeek API 配置 =====
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
# =============================

# Check if clipboard contains plain text (not files, images, etc.)
check_clipboard_is_text() {
    if command -v wl-paste &>/dev/null; then
        local types
        types=$(wl-paste --list-types 2>/dev/null)
        if [[ -z "$types" ]]; then
            return 2   # empty or unknown
        fi
        # image/* or text/uri-list → non-text (files, images)
        if echo "$types" | grep -qE '^image/|^text/uri-list'; then
            return 1
        fi
        if ! echo "$types" | grep -q 'text/plain'; then
            return 2   # no text/plain found, but not image/uri-list either
        fi
    elif command -v xclip &>/dev/null; then
        local targets
        targets=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null)
        if [[ -z "$targets" ]]; then
            return 2   # empty or unknown
        fi
        # image/* or text/uri-list → non-text (files, images)
        if echo "$targets" | grep -qE '^image/|^text/uri-list'; then
            return 1
        fi
        if ! echo "$targets" | grep -qE '^(STRING|TEXT|UTF8_STRING)$' && ! echo "$targets" | grep -q 'text/plain'; then
            return 2   # no text targets found, but not image/uri-list either
        fi
    fi
    return 0
}

get_clipboard() {
    local text=""
    if command -v wl-paste &>/dev/null; then
        text=$(wl-paste 2>/dev/null)
    fi
    if [[ -z "$text" ]] && command -v xclip &>/dev/null; then
        text=$(timeout 1 xclip -o -selection clipboard 2>/dev/null)
    fi
    if [[ -z "$text" ]] && command -v xsel &>/dev/null; then
        text=$(xsel -b 2>/dev/null)
    fi
    echo "$text"
}

show_sdcv_result() {
    local word="$1"
    local result
    result=$(sdcv -n "$word" 2>&1)
    if [[ $? -ne 0 ]] || [[ -z "$result" ]]; then
        notify-send -t 3000 "SDCV 查词" "未找到单词: $word"
        return 1
    fi
    if command -v zenity &>/dev/null; then
        printf '%s' "$result" | zenity --text-info \
            --title="SDCV: $word" \
            --width=600 --height=400 \
            --font="monospace 12" \
            --ok-label="知道了" \
            --cancel-label="关闭" 2>/dev/null
    else
        notify-send -t 15000 "SDCV: $word" "$result"
    fi
}

show_translation() {
    local text="$1" translation="$2"
    local len=${#text} w h

    if [[ $len -le 100 ]]; then
        w=600; h=400
    elif [[ $len -le 500 ]]; then
        w=800; h=500
    else
        w=1000; h=600
    fi

    if command -v zenity &>/dev/null; then
        printf '原文：\n\n%s\n\n译文：\n\n%s' "$text" "$translation" | \
            zenity --text-info \
                --title="在线翻译" \
                --width=$w --height=$h \
                --font="monospace 12" \
                --ok-label="知道了" \
                --cancel-label="关闭" 2>/dev/null
    else
        notify-send -t 15000 "翻译" "$translation"
    fi
}

call_deepseek_api() {
    local text="$1" payload response

    payload=$(python3 -c '
import json, sys
text = sys.argv[1]
model = sys.argv[2]
payload = {
    "model": model,
    "messages": [
        {
            "role": "system",
            "content": "你是专业翻译引擎。自动识别用户输入语言：如果是中文，翻译成英文；如果是英文，翻译成简体中文。只输出译文本身，不要解释、不要加引号、不要添加额外内容。保留原文中的换行、列表、代码块和专有名词格式。"
        },
        {"role": "user", "content": text}
    ],
    "stream": False
}
print(json.dumps(payload, ensure_ascii=False))
' "$text" "$DEEPSEEK_MODEL")

    response=$(curl -s "https://api.deepseek.com/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
        -d "$payload")

    echo "$response"
}

parse_translation() {
    local json="$1"
    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'error' in data:
    err = data.get('error', {})
    print('ERROR:' + err.get('message', '未知错误'))
    sys.exit(1)
choices = data.get('choices', [])
if not choices:
    print('ERROR:未返回翻译结果')
    sys.exit(1)
msg = choices[0].get('message', {})
content = msg.get('content', '')
if not content:
    print('ERROR:翻译内容为空')
    sys.exit(1)
print(content.strip())
"
}

# ==== 主流程 ====

check_clipboard_is_text
case $? in
    1)
        notify-send -t 3000 "⚠️ 只支持文本" "剪贴板内容不是纯文本，只支持文本查询/翻译"
        exit 1
        ;;
    2)
        notify-send -t 3000 "⚠️ 未知内容" "未知的剪贴板内容，无法查询/翻译"
        exit 1
        ;;
esac

RAW=$(get_clipboard)
if [[ -z "$RAW" ]]; then
    notify-send -t 3000 "翻译" "请先复制文本"
    exit 1
fi

# 判断是否单个英文单词
NO_SPACE=$(echo "$RAW" | tr -d '[:space:]')
if echo "$NO_SPACE" | grep -qE '^[a-zA-Z]+$'; then
    show_sdcv_result "$NO_SPACE"
    exit $?
fi

# 多词/句子 → DeepSeek 翻译
if [[ -z "$DEEPSEEK_API_KEY" ]]; then
    notify-send -t 5000 "翻译" "请先在脚本中配置 DeepSeek API Key"
    exit 1
fi

RESPONSE=$(call_deepseek_api "$RAW")
TRANSLATION=$(parse_translation "$RESPONSE")

if [[ "$TRANSLATION" == ERROR:* ]]; then
    notify-send -t 5000 "翻译出错" "${TRANSLATION#ERROR:}"
    exit 1
fi

if [[ -z "$TRANSLATION" ]]; then
    notify-send -t 5000 "翻译" "解析翻译结果失败"
    exit 1
fi

show_translation "$RAW" "$TRANSLATION"
