#!/bin/bash

# sarTracker.sh
#
# Samuel A. Hurley
# University of Wisconsin - Madison
# 19 March 2026
#
# 0.1 - Initial version
# 0.2 - implemented --smart-proc
# 0.3 - isolated file extraction to timestamped /tmp directory
# 0.4 - suppressed lx_ximg terminal output

# DICOM DICT
SCRIPTDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
export DCMDICTPATH="$SCRIPTDIR"/dicom.dic

# Default flag values
export_csv=false
ignore_orig=false
ignore_proc=false
smart_proc=false
examNumber=""
show_help=false

# Parse command line arguments
for arg in "$@"; do
    case "$arg" in
        --csv) export_csv=true ;;
        --ignore-orig) ignore_orig=true ;;
        --ignore-proc) ignore_proc=true ;;
        --smart-proc) smart_proc=true ;;
        -h|--help) show_help=true ;;
        -*) 
            echo "Error: Unknown parameter passed: $arg"
            exit 1 
            ;;
        *) 
            # If it doesn't start with a dash, assume it's the exam number
            examNumber="$arg" 
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
    echo "  -h, --help        Display this help screen and exit"
    echo ""
    echo "Example:"
    echo "  $(basename "$0") --csv --smart-proc 12345"
    exit 1
fi

# Create a temporary directory using the current datetime
datetime=$(date +"%Y%m%d_%H%M%S")
tmp_dir="/tmp/sarTracker_exam${examNumber}_${datetime}"
mkdir -p "$tmp_dir"

# Ensure the temp directory is ALWAYS deleted when the script exits or is aborted
trap 'echo "Cleaning up temporary directory..."; rm -rf "$tmp_dir"' EXIT

# 1. Run the command to dump the files into the temporary directory
echo "Fetching files for exam $examNumber into $tmp_dir..."
lx_ximg -d "$tmp_dir" "E${examNumber}SallI1" > /dev/null 2>&1

# Initialize the CSV file with headers if the flag was used (Saves to current working directory)
if [ "$export_csv" = true ]; then
    csv_file="exam_${examNumber}_summary.csv"
    echo "Series,Time,Description,SAR,Time(us),Time(M:S),SAR*Mins" > "$csv_file"
fi

# Print the terminal table header
printf "\n%-6s | %-5s | %-30s | %-8s | %-13s | %-10s | %-15s\n" "Series" "Time" "Description" "SAR" "Time(us)" "Time(M:S)" "SAR*Mins"
printf "%s\n" "--------------------------------------------------------------------------------------------------"

# Initialize variables for totals
total_time_sec=0
total_sar_time=0

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

    # Add to totals
    total_time_sec=$(awk -v total="$total_time_sec" -v sec="$dur_sec" 'BEGIN { printf "%.2f", total + sec }')
    total_sar_time=$(awk -v total="$total_sar_time" -v prod="$sar_time_prod" 'BEGIN { printf "%.4f", total + prod }')

    # 3. Display the row in the terminal
    printf "%-6s | %-5s | %-30s | %-8.4f | %-13s | %-10s | %-15.4f\n" "$series" "$clock_time" "${desc:0:30}" "$sar" "$duration_us" "$time_str" "$sar_time_prod"

    # Export the row to the CSV file if the flag was used
    if [ "$export_csv" = true ]; then
        echo "${series},${clock_time},\"${desc}\",${sar},${duration_us},${time_str},${sar_time_prod}" >> "$csv_file"
    fi

done

# Print the bottom separator for the terminal
printf "%s\n" "--------------------------------------------------------------------------------------------------"

# Calculate total time in MM:SS
total_mins=$(awk -v sec="$total_time_sec" 'BEGIN { printf "%d", sec / 60 }')
total_remainder_secs=$(awk -v sec="$total_time_sec" -v min="$total_mins" 'BEGIN { printf "%02.0f", sec - (min * 60) }')
total_time_str="${total_mins}:${total_remainder_secs}"

# 4. Display the final tally in the terminal
printf "%-6s   %-5s   %-30s   %-8s | %-13s | %-10s | %-15.4f\n\n" "TOTALS" "" "" "" "" "$total_time_str" "$total_sar_time"

# Append the final tally to the CSV file if the flag was used
if [ "$export_csv" = true ]; then
    echo "TOTALS,,,,,${total_time_str},${total_sar_time}" >> "$csv_file"
    echo "Done! Data successfully exported to: $csv_file"
fi

# Cleanup is handled automatically by the trap command at the top of the script.