#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# thermal_capture_policy <output-file>
# Captures runtime trip points and cooling-device bindings for all zones into a
# tab-separated artifact. Produces no stdout, exports policy counters, and
# returns 0 only when every discovered value is valid, 1 on capture or policy
# failure, or 3 for a missing output path. It does not change thermal state.
thermal_capture_policy() {
    tcp_output_file="$1"

    THERMAL_TRIP_COUNT=0
    THERMAL_BINDING_COUNT=0
    THERMAL_POLICY_INVALID_COUNT=0

    [ -n "$tcp_output_file" ] || return 3
    : >"$tcp_output_file" || return 1

    for tcp_zone in /sys/class/thermal/thermal_zone*; do
        [ -d "$tcp_zone" ] || continue
        tcp_zone_name=${tcp_zone##*/}
        tcp_zone_type=$(cat "$tcp_zone/type" 2>/dev/null || true)

        for tcp_trip_temp_file in "$tcp_zone"/trip_point_*_temp; do
            [ -r "$tcp_trip_temp_file" ] || continue
            tcp_trip_base=${tcp_trip_temp_file%_temp}
            tcp_trip_name=${tcp_trip_base##*/}
            tcp_trip_index=${tcp_trip_name#trip_point_}
            tcp_trip_temp=$(cat "$tcp_trip_temp_file" 2>/dev/null || true)
            tcp_trip_type=$(cat "${tcp_trip_base}_type" 2>/dev/null || true)
            THERMAL_TRIP_COUNT=$((THERMAL_TRIP_COUNT + 1))

            case "$tcp_trip_temp" in
                -* )
                    tcp_trip_digits=${tcp_trip_temp#-}
                    ;;
                *)
                    tcp_trip_digits=$tcp_trip_temp
                    ;;
            esac
            case "$tcp_trip_digits" in
                ''|*[!0-9]*)
                    THERMAL_POLICY_INVALID_COUNT=$((THERMAL_POLICY_INVALID_COUNT + 1))
                    ;;
                *)
                    if [ "$tcp_trip_temp" -lt -100000 ] ||
                       [ "$tcp_trip_temp" -gt 250000 ]; then
                        THERMAL_POLICY_INVALID_COUNT=$((THERMAL_POLICY_INVALID_COUNT + 1))
                    fi
                    ;;
            esac
            printf 'trip\t%s\t%s\t%s\t%s\n' \
                "$tcp_zone_name" \
                "${tcp_zone_type:-unknown}" \
                "$tcp_trip_index" \
                "${tcp_trip_type:-unknown}:temp_mC=${tcp_trip_temp:-unreadable}" >>"$tcp_output_file"
        done

        for tcp_cdev_link in "$tcp_zone"/cdev[0-9]*; do
            [ -L "$tcp_cdev_link" ] || continue
            tcp_cdev=$(readlink -f "$tcp_cdev_link")
            tcp_cdev_name=${tcp_cdev##*/}
            tcp_link_name=${tcp_cdev_link##*/}
            tcp_trip_binding=$(cat "$tcp_zone/${tcp_link_name}_trip_point" 2>/dev/null || true)
            tcp_weight=$(cat "$tcp_zone/${tcp_link_name}_weight" 2>/dev/null || true)
            THERMAL_BINDING_COUNT=$((THERMAL_BINDING_COUNT + 1))
            case "$tcp_trip_binding" in
                -1)
                    ;;
                ''|*[!0-9]*)
                    THERMAL_POLICY_INVALID_COUNT=$((THERMAL_POLICY_INVALID_COUNT + 1))
                    ;;
            esac
            case "$tcp_weight" in
                '')
                    ;;
                *[!0-9]*)
                    THERMAL_POLICY_INVALID_COUNT=$((THERMAL_POLICY_INVALID_COUNT + 1))
                    ;;
            esac
            printf 'binding\t%s\t%s\ttrip=%s\tweight=%s\n' \
                "$tcp_zone_name" \
                "$tcp_cdev_name" \
                "${tcp_trip_binding:-unknown}" \
                "${tcp_weight:-unknown}" >>"$tcp_output_file"
        done
    done

    export THERMAL_TRIP_COUNT THERMAL_BINDING_COUNT THERMAL_POLICY_INVALID_COUNT
    [ "$THERMAL_POLICY_INVALID_COUNT" -eq 0 ]
}

# thermal_log_policy <policy-file> [max-rows]
# Logs bounded trip and cooling-binding details retained by
# thermal_capture_policy. Produces no machine-readable stdout, returns 0 on
# success, 1 for an unreadable artifact, or 3 for an invalid row limit, and
# does not change thermal state.
thermal_log_policy() {
    tlp_policy_file="$1"
    tlp_max_rows="${2:-64}"
    tlp_total=0
    tlp_emitted=0

    [ -r "$tlp_policy_file" ] || return 1
    case "$tlp_max_rows" in
        ''|*[!0-9]*|0)
            return 3
            ;;
    esac

    tlp_total=$(wc -l <"$tlp_policy_file" 2>/dev/null | tr -d '[:space:]')
    while IFS="$(printf '\t')" read -r tlp_kind tlp_zone tlp_object tlp_value tlp_extra; do
        if [ "$tlp_emitted" -ge "$tlp_max_rows" ]; then
            break
        fi
        case "$tlp_kind" in
            trip)
                log_info "[THERMAL-TRIP] zone=$tlp_zone type=$tlp_object index=$tlp_value detail=$tlp_extra"
                ;;
            binding)
                log_info "[THERMAL-BINDING] zone=$tlp_zone cooling=$tlp_object trip=${tlp_value#trip=} weight=${tlp_extra#weight=}"
                ;;
            *)
                log_warn "[THERMAL-POLICY-ROW] kind=${tlp_kind:-missing} zone=${tlp_zone:-missing} observed=malformed"
                ;;
        esac
        tlp_emitted=$((tlp_emitted + 1))
    done <"$tlp_policy_file"

    if [ "$tlp_total" -gt "$tlp_emitted" ]; then
        log_info "[THERMAL-POLICY-ROW] omitted=$((tlp_total - tlp_emitted)) total=$tlp_total artifact=$tlp_policy_file"
    fi
}

# thermal_log_sample_summary <sample-file>
# Builds a retained TSV summary and logs phase-level temperature ranges,
# hottest zones, and cooling-state maxima. Produces no machine-readable stdout,
# returns 0 on success or 1 for unreadable, malformed, or empty evidence, and
# does not change thermal state.
thermal_log_sample_summary() {
    tlss_sample_file="$1"
    tlss_summary_file="${tlss_sample_file}.summary.tsv"

    [ -r "$tlss_sample_file" ] || return 1
    if ! awk -F '\t' '
        {
            phase=$2
            if (phase ~ /^load-/) {
                phase="load"
            }
        }
        $3 == "zone" {
            zone_count[phase]++
            if (!(phase in min_temp) || $5 < min_temp[phase]) {
                min_temp[phase]=$5
            }
            if (!(phase in max_temp) || $5 > max_temp[phase]) {
                max_temp[phase]=$5
                hottest[phase]=$4
            }
        }
        $3 == "cooling" {
            cooling_count[phase]++
            if (!(phase in max_cooling) || $5 > max_cooling[phase]) {
                max_cooling[phase]=$5
            }
        }
        END {
            order[1]="before"
            order[2]="load"
            order[3]="after"
            order[4]="recovery"
            for (phase_index=1; phase_index<=4; phase_index++) {
                phase=order[phase_index]
                if (zone_count[phase] > 0 || cooling_count[phase] > 0) {
                    printf "%s\t%d\t%s\t%s\t%s\t%d\t%s\n", phase,
                        zone_count[phase] + 0,
                        (phase in min_temp ? min_temp[phase] : "unavailable"),
                        (phase in max_temp ? max_temp[phase] : "unavailable"),
                        (phase in hottest ? hottest[phase] : "unavailable"),
                        cooling_count[phase] + 0,
                        (phase in max_cooling ? max_cooling[phase] : "unavailable")
                }
            }
        }
    ' "$tlss_sample_file" >"$tlss_summary_file"; then
        return 1
    fi

    [ -s "$tlss_summary_file" ] || return 1
    while IFS="$(printf '\t')" read -r tlss_phase tlss_zones tlss_min tlss_max tlss_hottest tlss_cooling tlss_cooling_max; do
        log_info "[THERMAL-SAMPLE] phase=$tlss_phase zones=$tlss_zones min_temp_mC=$tlss_min max_temp_mC=$tlss_max hottest_zone=$tlss_hottest cooling_devices=$tlss_cooling max_cooling_state=$tlss_cooling_max samples=$tlss_sample_file summary=$tlss_summary_file"
    done <"$tlss_summary_file"
}

# thermal_capture_sample <output-file> <phase>
# Appends one timestamped phase sample of readable thermal-zone temperatures
# and cooling-device states to the supplied TSV file. Produces no stdout and
# returns 0 when at least one temperature is readable, 1 otherwise, or 3 for
# invalid arguments. It does not change thermal state.
thermal_capture_sample() {
    tcs_output_file="$1"
    tcs_phase="$2"
    tcs_timestamp=$(date +%s)
    tcs_readable=0

    [ -n "$tcs_output_file" ] && [ -n "$tcs_phase" ] || return 3

    for tcs_zone in /sys/class/thermal/thermal_zone*; do
        [ -d "$tcs_zone" ] || continue
        tcs_temp=$(cat "$tcs_zone/temp" 2>/dev/null || true)
        case "$tcs_temp" in
            -*)
                tcs_temp_digits=${tcs_temp#-}
                ;;
            *)
                tcs_temp_digits=$tcs_temp
                ;;
        esac
        case "$tcs_temp_digits" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
        tcs_readable=$((tcs_readable + 1))
        printf '%s\t%s\tzone\t%s\t%s\n' \
            "$tcs_timestamp" \
            "$tcs_phase" \
            "${tcs_zone##*/}" \
            "$tcs_temp" >>"$tcs_output_file"
    done

    for tcs_cdev in /sys/class/thermal/cooling_device*; do
        [ -d "$tcs_cdev" ] || continue
        tcs_state=$(cat "$tcs_cdev/cur_state" 2>/dev/null || true)
        case "$tcs_state" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
        printf '%s\t%s\tcooling\t%s\t%s\n' \
            "$tcs_timestamp" \
            "$tcs_phase" \
            "${tcs_cdev##*/}" \
            "$tcs_state" >>"$tcs_output_file"
    done

    [ "$tcs_readable" -gt 0 ]
}

# thermal_sample_max_rise <sample-file>
# Prints one integer in milli-Celsius representing the largest load or
# post-load increase over the pre-load temperature. Returns 0 with a value, 1
# when no comparable samples exist, or 3 for an unreadable input artifact.
thermal_sample_max_rise() {
    tsmr_sample_file="$1"

    [ -r "$tsmr_sample_file" ] || return 3
    awk -F '\t' '
        $3 == "zone" && $2 == "before" { before[$4]=$5 }
        $3 == "zone" && $2 != "before" && $2 != "recovery" && ($4 in before) {
            delta=$5-before[$4]
            if (!seen || delta > maximum) {
                maximum=delta
                seen=1
            }
        }
        END {
            if (!seen) {
                exit 1
            }
            print maximum
        }
    ' "$tsmr_sample_file"
}

# thermal_sample_max_cooling_increase <sample-file>
# Prints the largest cooling-device state increase observed during or after
# the controlled load. Zero is a valid stdout result when no throttling was
# required. Returns 0 with a value, 1 when no comparable samples exist, or 3
# for an unreadable input artifact.
thermal_sample_max_cooling_increase() {
    tsmci_sample_file="$1"

    [ -r "$tsmci_sample_file" ] || return 3
    awk -F '\t' '
        $3 == "cooling" && $2 == "before" { before[$4]=$5 }
        $3 == "cooling" && $2 != "before" && $2 != "recovery" && ($4 in before) {
            delta=$5-before[$4]
            if (!seen || delta > maximum) {
                maximum=delta
                seen=1
            }
        }
        END {
            if (!seen) {
                exit 1
            }
            print maximum
        }
    ' "$tsmci_sample_file"
}

# thermal_stop_controlled_load
# Takes no arguments and produces no stdout. Stops and reaps only the process
# identified by THERMAL_CONTROLLED_LOAD_PID, clears that exported ownership
# variable, and leaves retained load evidence in place.
thermal_stop_controlled_load() {
    if [ -n "${THERMAL_CONTROLLED_LOAD_PID:-}" ] &&
       kill -0 "$THERMAL_CONTROLLED_LOAD_PID" 2>/dev/null; then
        kill "$THERMAL_CONTROLLED_LOAD_PID" 2>/dev/null || true
        wait "$THERMAL_CONTROLLED_LOAD_PID" 2>/dev/null || true
    fi
    THERMAL_CONTROLLED_LOAD_PID=""
    export THERMAL_CONTROLLED_LOAD_PID
}

# thermal_run_controlled_load <sample-file> <log-file> <seconds> <workers>
# Runs stress-ng with its own duration plus an outer watchdog while collecting
# one thermal and cooling-state sample per second. Produces no stdout, exports
# process ownership and sample-failure counters, returns the stress-ng status or
# 124 on watchdog expiry, and leaves cleanup to thermal_stop_controlled_load.
thermal_run_controlled_load() {
    trcl_sample_file="$1"
    trcl_log_file="$2"
    trcl_seconds="$3"
    trcl_workers="$4"
    trcl_elapsed=0
    trcl_limit=$((trcl_seconds + 10))

    THERMAL_LOAD_SAMPLE_FAILURES=0
    stress-ng --cpu "$trcl_workers" --timeout "${trcl_seconds}s" --metrics-brief \
        >"$trcl_log_file" 2>&1 &
    THERMAL_CONTROLLED_LOAD_PID=$!
    export THERMAL_CONTROLLED_LOAD_PID

    while kill -0 "$THERMAL_CONTROLLED_LOAD_PID" 2>/dev/null; do
        if ! thermal_capture_sample \
            "$trcl_sample_file" \
            "load-$trcl_elapsed"; then
            THERMAL_LOAD_SAMPLE_FAILURES=$((THERMAL_LOAD_SAMPLE_FAILURES + 1))
        fi
        if [ "$trcl_elapsed" -ge "$trcl_limit" ]; then
            thermal_stop_controlled_load
            export THERMAL_LOAD_SAMPLE_FAILURES
            return 124
        fi
        sleep 1
        trcl_elapsed=$((trcl_elapsed + 1))
    done

    wait "$THERMAL_CONTROLLED_LOAD_PID"
    trcl_rc=$?
    THERMAL_CONTROLLED_LOAD_PID=""
    export THERMAL_CONTROLLED_LOAD_PID THERMAL_LOAD_SAMPLE_FAILURES
    return "$trcl_rc"
}
