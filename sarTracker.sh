#!/bin/bash

# sarTracker.sh
#
# Samuel A. Hurley
# University of Wisconsin - Madison
# 25 September 2026
#
# 0.1 - Initial version
# 0.2 - implemented --smart-proc
# 0.3 - isolated file extraction to timestamped /tmp directory
# 0.4 - suppressed lx_ximg terminal output
# 0.5 - implemented --sar-mode and Eff Time column
# 0.6 - tightened terminal output columns
# 0.7 - further tightened SAR column and divider lines
# 1.0 - reordered columns, hid Time(us), and added auto SAR limit detection
# 1.1 - refactored code for detecting SAR mode
# 1.2 - removed deprecated tags, updated display names
# 1.3 - fixed parsing bug caused by dcmdump string truncation
# 1.4 - replaced awk with cut for bracket parsing to silence warnings
# 1.5 - added --break-after flag to reset running totals for implant cooldowns
# 1.6 - replaced lx_ximg dependency with native bash extraction function

# DICOM DICT
SCRIPTDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export DCMDICTPATH="$SCRIPTDIR"/dicom.dic

# Default flag values
export_csv=false
ignore_orig=false
ignore_proc=false
smart_proc=false
examNumber=""
sar_limit=""
expect_sar_limit=false
break_series=()
expect_break_after=false
show_help=false

# Parse command line arguments
for arg in "$@"; do
    # Capture argument values for flags that require them
    if [ "$expect_sar_limit" = true ]; then
        sar_limit="$arg"
        expect_sar_limit=false
        continue
    fi
    if [ "$expect_break_after" = true ]; then
        IFS=',' read -ra ADDR <<< "$arg"
        break_series+=("${ADDR[@]}")
        expect_break_after=false
        continue
    fi

    case "$arg" in
        --csv) export_csv=true ;;
        --ignore-orig) ignore_orig=true ;;
        --ignore-proc) ignore_proc=true ;;
        --smart-proc) smart_proc=true ;;
        --sar-mode) expect_sar_limit=true ;;
        --sar-mode=*) sar_limit="${arg#*=}" ;;
        --break-after) expect_break_after=true ;;
        --break-after=*) 
            IFS=',' read -ra ADDR <<< "${arg#*=}"
            break_series+=("${ADDR[@]}") 
            ;;
        -h|--help) show_help=true ;;
        -*) 
            echo "Error: Unknown parameter passed: $arg"
            exit 1 
            ;;
        *) 
            # If it doesn't start with a dash, assume it's the exam number
            # Remove any non-numeric characters (e.g. accidental trailing slashes)
            examNumber="${arg//[^0-9]/}" 
            ;;
    esac
done

# Display usage help screen if no exam number is provided or if help was requested
if [ "$show_help" = true ] || [ -z "$examNumber" ]; then
    echo "Usage: $(basename "$0") [OPTIONS] EXAM_NUMBER"
    echo ""
    echo "Arguments:"
    echo "  EXAM_NUMBER       The numeric exam ID to process"
    echo ""
    echo "Options:"
    echo "  --csv             Export results to a CSV file"
    echo "  --ignore-orig     Ignore series starting with 'ORIG' or containing 'screen save'"
    echo "  --ignore-proc     Strictly ignore ALL processed series (Series number >= 100)"
    echo "  --smart-proc      Ignore processed series if base exists. Limits to 2 if base is missing."
    echo "  --sar-mode LIMIT  Override auto-detected SAR limit (W/kg) for effective time calc"
    echo "  --break-after NUM Specify a series number (or comma-separated list) to reset totals after"
    echo "  -h, --help        Display this help screen and exit"
    echo ""
    echo "Example:"
    echo "  $(basename "$0") --csv --smart-proc --break-after 5,10 12345"
    exit 1
fi

# Create a temporary directory using the current datetime
datetime=$(date +"%Y%m%d_%H%M%S")
tmp_dir="/tmp/sarTracker_exam${examNumber}_${datetime}"
mkdir -p "$tmp_dir"

# Ensure the temp directory is ALWAYS deleted when the script exits or is aborted
trap 'echo "Cleaning up temporary directory..."; rm -rf "$tmp_dir"' EXIT

# --- Helper Functions ---

# Helper function to print the dynamic totals
print_totals() {
    local label="$1"
    
    # Calculate total time in MM:SS
    local total_mins=$(awk -v sec="$total_time_sec" 'BEGIN { printf "%d", sec / 60 }')
    local total_remainder_secs=$(awk -v sec="$total_time_sec" -v min="$total_mins" 'BEGIN { printf "%02.0f", sec - (min * 60) }')
    local total_time_str="${total_mins}:${total_remainder_secs}"

    # Calculate total effective time in MM:SS (if sar_limit was determined)
    local total_eff_time_str="N/A"
    if [ -n "$sar_limit" ]; then
        local total_eff_mins=$(awk -v sec="$total_eff_time_sec" 'BEGIN { printf "%d", sec / 60 }')
        local total_eff_remainder_secs=$(awk -v sec="$total_eff_time_sec" -v min="$total_eff_mins" 'BEGIN { printf "%02.0f", sec - (min * 60) }')
        total_eff_time_str="${total_eff_mins}:${total_eff_remainder_secs}"
    fi

    # Display the tally in the terminal
    printf "%-6s   %-5s   %-30s   %-6s | %-8.4f | %-9s | %-8s\n" "$label" "" "" "" "$total_sar_time" "$total_time_str" "$total_eff_time_str"

    # Append to the CSV file if the flag was used
    if [ "$export_csv" = true ]; then
        echo "${label},,,,${total_sar_time},,${total_time_str},${total_eff_time_str}" >> "$csv_file"
    fi
}

# Helper function to extract Image 1 from all series in a given exam
extract_images() {
    local exam_num="$1"
    local out_dir="$2"
    local ge_db_dir="/export/home1/sdc_image_pool/images"
    local exam_found=false

    echo "Searching GE database for exam $exam_num..."

    # 1. Loop through all hpat/exam directories
    for exam_dir in "$ge_db_dir"/*/*; do
        [ -d "$exam_dir" ] || continue

        # Grab the first image of the first series to check the Exam Number
        local first_img=$(ls "$exam_dir"/*/* 2>/dev/null | grep -iE 'i[0-9]+\.mrdc\.[0-9]+' | head -n 1)
        [ -z "$first_img" ] && continue

        # Extract (0020,0010) Study ID (Exam Number)
        local current_exam=$(dcmdump "$first_img" 2>/dev/null | grep -i "0020,0010" | awk -F'[' '{print $2}' | cut -d']' -f1 | tr -d ' ')

        if [ "$current_exam" == "$exam_num" ]; then
            exam_found=true
            echo "Dumping files for exam $exam_num into $out_dir..."
            
            # 2. Loop through all series directories inside this exam
            for series_dir in "$exam_dir"/*; do
                [ -d "$series_dir" ] || continue
                
                # Get the Series Number (0020,0011)
                local series_img=$(ls "$series_dir"/* 2>/dev/null | grep -iE 'i[0-9]+\.mrdc\.[0-9]+' | head -n 1)
                [ -z "$series_img" ] && continue
                local series_num=$(dcmdump "$series_img" 2>/dev/null | grep -i "0020,0011" | awk -F'[' '{print $2}' | cut -d']' -f1 | tr -d ' ')
                
                # 3. Find Image 1 in this series using GE's filename extension
                for img_file in "$series_dir"/i*.MRDC.*; do
                    [ -e "$img_file" ] || continue
                    local img_num="${img_file##*.MRDC.}" # Bash string manipulation to extract number after .MRDC.
                    
                    if [ "$img_num" == "1" ]; then
                        # Copy and rename to perfectly match the old lx_ximg output format
                        cp "$img_file" "$out_dir/E${exam_num}S${series_num}I1.MR.dcm"
                        break # Found Image 1, move to the next series
                    fi
                done
            done
            break # We found and processed the exam, stop searching the database
        fi
    done

    if [ "$exam_found" = false ]; then
        echo "Error: Exam $exam_num not found in GE database ($ge_db_dir)."
        return 1
    fi
    return 0
}

# ----------------------------

# 1. Run the native bash extraction function
if ! extract_images "$examNumber" "$tmp_dir"; then
    exit 1
fi

# --- Auto-Detect SAR Mode ---
first_file=$(ls "$tmp_dir"/E"${examNumber}"S*I1.MR.dcm 2>/dev/null | head -n 1)
sar_display_text=""

# If --sar-mode was provided, it overrides. Otherwise, try to auto-detect.
if [ -n "$sar_limit" ]; then
    sar_display_text="Manual SAR Limit ($sar_limit W/kg)"
elif [ -n "$first_file" ] && [ -f "$first_file" ]; then
    
    # Extract the dynamic limit tags (using cut to safely bypass dcmdump truncation and awk warnings)
    limit_labels=$(dcmdump "$first_file" 2>/dev/null | grep -i "0043,1090" | awk -F'#' '{print $1}' | cut -d'[' -f2 | tr -d ']')
    limit_values=$(dcmdump "$first_file" 2>/dev/null | grep -i "0043,1091" | awk -F'#' '{print $1}' | cut -d'[' -f2 | tr -d ']')

    # 1. Check if scanner dynamically generated a custom constraint (Low SAR or B1+rms)
    if [[ "$limit_labels" == *"LOWSAR_B1PEAK"* ]]; then
        IFS='\' read -ra val_arr <<< "$limit_values"
        raw_limit="${val_arr[0]}" # Index 0 holds the enforced Whole Body SAR limit
        
        if [ -n "$raw_limit" ]; then
            # Clean up floating point slop from the GE header (e.g., 0.9999 -> 1.0)
            sar_limit=$(awk -v val="$raw_limit" 'BEGIN { printf "%.1f", val }')
            display_mode_name="Low SAR Mode"
            assumed_normal=false
            sar_display_text="Auto-detected $display_mode_name ($sar_limit W/kg)"
        fi
    else
        # 2. Proceed with normal SAR detection
        ge_private_mode_raw=$(dcmdump "$first_file" 2>/dev/null | grep -i "0043,1089" | awk -F'#' '{print $1}' | cut -d'[' -f2 | tr -d ']')

        # Extract the 3rd element (SAR limit) from the GE private tag to avoid dB/dt false positives
        IFS='\' read -ra ge_priv_arr <<< "$ge_private_mode_raw"
        ge_sar_mode="${ge_priv_arr[2]}"
        
        # Fallback if the tag doesn't contain exactly 3 elements
        if [ -z "$ge_sar_mode" ]; then
            ge_sar_mode="$ge_private_mode_raw"
        fi

        detected_mode="UNKNOWN"
        assumed_normal=false

        if [[ "$ge_sar_mode" == *"FIRST_LEVEL"* ]]; then
            detected_mode="FIRST_LEVEL"
        elif [[ "$ge_sar_mode" == *"NORMAL"* ]]; then
            detected_mode="NORMAL"
        else
            detected_mode="NORMAL"
            assumed_normal=true
        fi

        # Determine the SAR Limit and friendly display name based on the mode
        display_mode_name="$detected_mode"
        case "$detected_mode" in
            "FIRST_LEVEL") 
                sar_limit="4.0" 
                display_mode_name="SAR First Level"
                ;;
            "NORMAL")      
                sar_limit="2.0" 
                display_mode_name="SAR Normal Mode"
                ;;
        esac
        
        # Set display text based on findings
        if [ -n "$sar_limit" ]; then
            if [ "$assumed_normal" = true ]; then
                sar_display_text="Auto-detected SAR Normal Mode [Assumed] ($sar_limit W/kg)"
            else
                sar_display_text="Auto-detected $display_mode_name ($sar_limit W/kg)"
            fi
        fi
    fi
fi
# ----------------------------

# Initialize the CSV file with headers if the flag was used (Saves to current working directory)
if [ "$export_csv" = true ]; then
    csv_file="exam_${examNumber}_summary.csv"
    echo "Series,Time,Description,SAR,SAR*Mins,Time(us),Time(M:S),Eff Time" > "$csv_file"
fi

# Print the terminal table header
if [ -n "$sar_display_text" ]; then
    printf "\nSAR Mode: %s" "$sar_display_text"
fi
printf "\n%-6s | %-5s | %-30s | %-6s | %-8s | %-9s | %-8s\n" "Series" "Time" "Description" "SAR" "SAR*Mins" "Time(M:S)" "Eff Time"
printf "%s\n" "-------------------------------------------------------------------------------------------"

# Initialize variables for totals
total_time_sec=0
total_sar_time=0
total_eff_time_sec=0

# Trackers for smart-proc logic to limit reconstructed series to 2 maximum
current_smart_base=-1
smart_base_count=0

# Pre-sort the files using a "double sort" (Base group first, then actual series number)
sorted_files=$(
    for f in "$tmp_dir"/E"${examNumber}"S*I1.MR.dcm; do
        [ -e "$f" ] || continue
        s_tmp="${f#*E${examNumber}S}"
        s="${s_tmp%%I1*}"
        
        # Determine sorting base to group reconstructed series (>=100) with their origins
        sort_base="$s"
        if [ "$s" -ge 100 ] 2>/dev/null; then
            sort_base=$((s / 100))
        fi
        
        echo "$sort_base:$s:$f"
    done | sort -t: -k1,1n -k2,2n | cut -d: -f3
)

# 2. Loop through the generated DICOM files
for file in $sorted_files; do
    
    # Check if file exists
    [ -e "$file" ] || continue

    # Extract Series Number directly from the filename
    series_tmp="${file#*E${examNumber}S}"
    series="${series_tmp%%I1*}"

    # Check if we need to completely ignore processed series
    if [ "$ignore_proc" = true ] && [ "$series" -ge 100 ] 2>/dev/null; then
        continue
    fi

    # Check if we need to smartly ignore processed series
    if [ "$smart_proc" = true ] && [ "$series" -ge 100 ] 2>/dev/null; then
        
        # Divide by 100 to get the base (e.g., 300 -> 3, 401 -> 4, 1500 -> 15)
        base=$((series / 100))
        
        # If the original base series file exists in the directory, skip this recon entirely
        if [ -f "$tmp_dir/E${examNumber}S${base}I1.MR.dcm" ]; then
            continue
        fi

        # If base doesn't exist, limit to the first 2 processed series
        if [ "$base" != "$current_smart_base" ]; then
            # We hit a new base, reset the counter to 1
            current_smart_base=$base
            smart_base_count=1
        else
            # We are on the same base, increment the counter
            smart_base_count=$((smart_base_count + 1))
        fi

        # If we have already included 2 for this base, skip any subsequent ones
        if [ "$smart_base_count" -gt 2 ]; then
            continue
        fi
    fi

    # a. Series Description (Tag 0008,103e)
    desc=$(dcmdump "$file" | grep -i "0008,103e" | sed -n 's/.*\[\(.*\)\].*/\1/p' | head -n 1)
    [ -z "$desc" ] && desc="N/A"

    # Check if we need to ignore series starting with "ORIG" or containing "screen save"
    if [ "$ignore_orig" = true ]; then
        desc_lower=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
        if [[ "$desc" == ORIG* ]] || [[ "$desc_lower" == *"screen save"* ]]; then
            continue
        fi
    fi

    # b. Clock Time (Tag 0008,0031)
    # Extracts the string, removes brackets, and slices the HHMM string into HH:MM
    time_raw=$(dcmdump "$file" | grep -i "0008,0031" | head -n 1 | awk -F'#' '{print $1}' | awk '{print $NF}' | tr -d '[]')
    if [[ ${#time_raw} -ge 4 ]]; then
        clock_time="${time_raw:0:2}:${time_raw:2:2}"
    else
        clock_time="N/A"
    fi

    # c. Image duration (Tag 0019,105a)
    duration_us=$(dcmdump "$file" | grep -i "0019,105a" | head -n 1 | awk -F'#' '{print $1}' | grep -o -iE '[0-9]*\.?[0-9]+(e[-+]?[0-9]+)?' | tail -n 1)
    [ -z "$duration_us" ] && duration_us=0

    # Convert microseconds to total seconds
    dur_sec=$(awk -v us="$duration_us" 'BEGIN { printf "%.2f", us / 1000000 }')
    
    # Calculate minutes and remaining seconds for display
    dur_mins=$(awk -v sec="$dur_sec" 'BEGIN { printf "%d", sec / 60 }')
    dur_remainder_secs=$(awk -v sec="$dur_sec" -v min="$dur_mins" 'BEGIN { printf "%02.0f", sec - (min * 60) }')
    time_str="${dur_mins}:${dur_remainder_secs}"

    # d. SAR Values (Tag 0018,1316)
    sar=$(dcmdump "$file" | grep -i "0018,1316" | head -n 1 | awk -F'#' '{print $1}' | grep -o -iE '[0-9]*\.?[0-9]+(e[-+]?[0-9]+)?' | tail -n 1)
    [ -z "$sar" ] && sar=0

    # Calculate SAR * duration product (using minutes for the multiplier)
    sar_time_prod=$(awk -v sar="$sar" -v sec="$dur_sec" 'BEGIN { printf "%.4f", sar * (sec / 60) }')

    # e. Effective Time Calculation (if sar_limit was determined)
    if [ -n "$sar_limit" ]; then
        # Calculate effective time in total seconds to easily format to MM:SS
        eff_sec=$(awk -v prod="$sar_time_prod" -v limit="$sar_limit" 'BEGIN { if(limit>0) printf "%.2f", (prod / limit) * 60; else print "0" }')
        
        eff_mins=$(awk -v sec="$eff_sec" 'BEGIN { printf "%d", sec / 60 }')
        eff_remainder_secs=$(awk -v sec="$eff_sec" -v min="$eff_mins" 'BEGIN { printf "%02.0f", sec - (min * 60) }')
        eff_time_str="${eff_mins}:${eff_remainder_secs}"
        
        # Add to total effective seconds tracking
        total_eff_time_sec=$(awk -v total="$total_eff_time_sec" -v sec="$eff_sec" 'BEGIN { printf "%.2f", total + sec }')
    else
        eff_time_str="N/A"
    fi

    # Add to totals
    total_time_sec=$(awk -v total="$total_time_sec" -v sec="$dur_sec" 'BEGIN { printf "%.2f", total + sec }')
    total_sar_time=$(awk -v total="$total_sar_time" -v prod="$sar_time_prod" 'BEGIN { printf "%.4f", total + prod }')

    # 3. Display the row in the terminal
    printf "%-6s | %-5s | %-30s | %-6.4f | %-8.4f | %-9s | %-8s\n" "$series" "$clock_time" "${desc:0:30}" "$sar" "$sar_time_prod" "$time_str" "$eff_time_str"

    # Export the row to the CSV file if the flag was used
    if [ "$export_csv" = true ]; then
        echo "${series},${clock_time},\"${desc}\",${sar},${sar_time_prod},${duration_us},${time_str},${eff_time_str}" >> "$csv_file"
    fi

    # 4. Check if the user specified a break after this series
    is_break=false
    for b in "${break_series[@]}"; do
        if [ "$series" == "$b" ]; then
            is_break=true
            break
        fi
    done

    if [ "$is_break" = true ]; then
        printf "%s\n" "-------------------------------------------------------------------------------------------"
        print_totals "BREAK"
        printf "%s\n" "-------------------------------------------------------------------------------------------"
        
        # Reset total trackers for the next batch
        total_time_sec=0
        total_sar_time=0
        total_eff_time_sec=0
    fi

done

# Print the bottom separator for the terminal
printf "%s\n" "-------------------------------------------------------------------------------------------"

# Print final totals
print_totals "TOTALS"
echo ""

if [ "$export_csv" = true ]; then
    echo "Done! Data successfully exported to: $csv_file"
fi

# Cleanup is handled automatically by the trap command at the top of the script.