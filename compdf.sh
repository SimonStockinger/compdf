#!/usr/bin/env bash

set -eo pipefail

# Check if qpdf is installed
if ! command -v qpdf &>/dev/null; then
    echo "Please install qpdf (e.g., via 'sudo apt install qpdf' or 'brew install qpdf')." >&2
    exit 1
fi

# Parse parameters
if [ "$#" -eq 1 ]; then
    PAGE_FILE=""
    SOURCE_PDF="$1"
elif [ "$#" -eq 2 ]; then
    PAGE_FILE="$1"
    SOURCE_PDF="$2"
else
    echo "Usage:"
    echo "  compdf pages.txt source.pdf"
    echo "  compdf source.pdf"
    exit 1
fi

# Verify that the source file exists
if [ ! -f "$SOURCE_PDF" ]; then
    echo "Error: Source file '$SOURCE_PDF' not found." >&2
    exit 1
fi

OUTPUT_PDF="${SOURCE_PDF%.pdf}_extracted.pdf"

# Interactive mode if no page file was provided
if [ -z "$PAGE_FILE" ]; then
    PAGE_FILE=$(mktemp)
    trap 'rm -f "$PAGE_FILE"' EXIT

    echo "--- Interactive Mode ---"
    echo "Enter page numbers or ranges (e.g., '1', '3-5', '8')."
    echo "Confirm each entry with [Enter]."
    echo "Press [ESC] or [q] to finish input and compile the PDF."
    echo "------------------------"

    current_input=""

    while true; do
        # Read character-by-character without echo (-s -n 1)
        IFS= read -rs -n 1 char

        # Handle Escape key
        if [[ "$char" == $'\e' ]]; then
            # Check buffer (arrow keys also send escape sequences)
            read -rsn 2 -t 0.001 rest || true
            if [[ -z "$rest" ]]; then
                echo ""
                break
            fi
            continue
        fi

        # Handle 'q' or 'Q' exit (only if current line buffer is empty)
        if [[ "$char" == "q" || "$char" == "Q" ]] && [[ -z "$current_input" ]]; then
            echo ""
            break
        fi

        # Handle Enter key
        if [[ "$char" == "" ]]; then
            echo ""
            trimmed_input=$(echo "$current_input" | xargs)
            if [ -n "$trimmed_input" ]; then
                echo "$trimmed_input" >> "$PAGE_FILE"
            fi
            current_input=""
            continue
        fi

        # Handle Backspace / Delete
        if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if [ -n "$current_input" ]; then
                current_input="${current_input%?}"
                printf "\b \b"
            fi
            continue
        fi

        # Append character to buffer and print to screen
        current_input+="$char"
        printf "%s" "$char"
    done
else
    if [ ! -f "$PAGE_FILE" ]; then
        echo "Error: Page file '$PAGE_FILE' not found." >&2
        exit 1
    fi
fi

# Expand ranges & collect individual page numbers
raw_pages=$(grep -v '^[[:space:]]*$' "$PAGE_FILE" | grep -v '^[[:space:]]*#' | tr ',' '\n' | sed 's/[[:space:]]//g')

expanded_pages=()
while IFS= read -r token; do
    [ -z "$token" ] && continue

    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        if [ "$start" -le "$end" ]; then
            for ((p = start; p <= end; p++)); do
                expanded_pages+=("$p")
            done
        else
            for ((p = start; p >= end; p--)); do
                expanded_pages+=("$p")
            done
        fi
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
        expanded_pages+=("$token")
    else
        echo "Warning: Ignoring invalid token '$token'" >&2
    fi
done <<< "$raw_pages"

# Sort numerically & remove duplicates
sorted_unique=()
if [ "${#expanded_pages[@]}" -gt 0 ]; then
    while IFS= read -r p; do
        sorted_unique+=("$p")
    done < <(printf '%s\n' "${expanded_pages[@]}" | sort -nu)
fi

if [ "${#sorted_unique[@]}" -eq 0 ]; then
    echo "No valid page numbers found. Aborting..."
    exit 0
fi

# Compact consecutive sequences back into ranges (e.g., 1, 2, 3 -> 1-3)
compact_ranges=()
range_start="${sorted_unique[0]}"
prev="${sorted_unique[0]}"

for ((i = 1; i < ${#sorted_unique[@]}; i++)); do
    curr="${sorted_unique[i]}"
    if [ "$curr" -eq "$((prev + 1))" ]; then
        prev="$curr"
    else
        if [ "$range_start" -eq "$prev" ]; then
            compact_ranges+=("$range_start")
        else
            compact_ranges+=("${range_start}-${prev}")
        fi
        range_start="$curr"
        prev="$curr"
    fi
done

if [ "$range_start" -eq "$prev" ]; then
    compact_ranges+=("$range_start")
else
    compact_ranges+=("${range_start}-${prev}")
fi

PAGE_SELECTION=$(IFS=,; echo "${compact_ranges[*]}")

echo "Extracting pages: $PAGE_SELECTION"
echo "Creating: $OUTPUT_PDF ..."

# Run qpdf to extract the selected pages
qpdf "$SOURCE_PDF" --pages "$SOURCE_PDF" "$PAGE_SELECTION" -- "$OUTPUT_PDF"

echo "Done! Compiled file saved under: $OUTPUT_PDF"
