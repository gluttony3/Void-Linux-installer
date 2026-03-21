#!/usr/bin/env bash
# detect.sh — CPU, GPU and disk-type detection

# Exported variables: CPU_VENDOR, GPU_TYPE, DISK_TYPE

detect_cpu() {
    local cpuinfo
    cpuinfo=$(grep -m1 "vendor_id" /proc/cpuinfo 2>/dev/null || true)
    if echo "$cpuinfo" | grep -qi "GenuineIntel"; then
        CPU_VENDOR="intel"
    elif echo "$cpuinfo" | grep -qi "AuthenticAMD"; then
        CPU_VENDOR="amd"
    else
        CPU_VENDOR="unknown"
    fi
    export CPU_VENDOR
}

detect_gpu() {
    local gpu_info has_intel=0 has_amd=0 has_nvidia=0

    if command -v lspci &>/dev/null; then
        gpu_info=$(lspci 2>/dev/null | grep -iE "vga|3d controller|display controller" || true)
    else
        gpu_info=""
    fi

    echo "$gpu_info" | grep -qi "intel"           && has_intel=1
    echo "$gpu_info" | grep -qi "amd\|radeon\|ati" && has_amd=1
    echo "$gpu_info" | grep -qi "nvidia"           && has_nvidia=1

    if   (( has_intel && has_nvidia )); then
        GPU_TYPE="hybrid_intel_nvidia"
    elif (( has_nvidia )); then
        GPU_TYPE="nvidia"
    elif (( has_amd )); then
        GPU_TYPE="amd"
    elif (( has_intel )); then
        GPU_TYPE="intel"
    else
        GPU_TYPE="generic"
    fi

    export GPU_TYPE
}

detect_disk_type() {
    local disk="${1##*/}"   # strip /dev/ prefix
    local rotational="/sys/block/${disk}/queue/rotational"

    if [[ -f "$rotational" ]] && [[ "$(cat "$rotational")" == "0" ]]; then
        DISK_TYPE="ssd"
    else
        DISK_TYPE="hdd"
    fi
    export DISK_TYPE
}
