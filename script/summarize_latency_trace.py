#!/usr/bin/env python3
"""명시적으로 수집한 숫자 전용 AirTranslate 로그를 요약한다."""

import argparse
from collections import Counter, defaultdict, deque
import json
import math
from pathlib import Path
import statistics


def distribution(values):
    values = sorted(value for value in values if math.isfinite(value) and value >= 0)
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "p50_ms": round(statistics.median(values), 3),
        "p95_ms": round(values[math.ceil(len(values) * 0.95) - 1], 3),
        "max_ms": round(values[-1], 3),
    }


def summarize(events):
    stages = Counter(event["stage"] for event in events)
    pending_speech = defaultdict(deque)
    pending_translation = defaultdict(deque)
    dispatch, translations, capture_delay = [], [], []
    first_source = None
    first_translation = None
    for event in events:
        stage, timestamp = event["stage"], event["uptime"]
        characters = event.get("characters")
        if stage == "speech.result":
            pending_speech[characters].append(timestamp)
        elif stage == "speech.received":
            if "dispatch_ms" in event:
                dispatch.append(event["dispatch_ms"])
            elif pending_speech[characters]:
                dispatch.append((timestamp - pending_speech[characters].popleft()) * 1000)
        elif stage == "speech.audio":
            capture_delay.append((timestamp - event["capture_time"] - event["duration"]) * 1000)
        elif stage == "translation.start":
            pending_translation[(event.get("id"), characters)].append(timestamp)
        elif stage == "translation.result":
            pending = pending_translation[(event.get("id"), characters)]
            if pending:
                translations.append((timestamp - pending.popleft()) * 1000)
        if stage == "floating.source" and first_source is None:
            first_source = timestamp
        if stage == "translation.apply" and first_translation is None:
            first_translation = timestamp

    return {
        "schema": "airtranslate.latency-summary.v1",
        "stages": dict(stages),
        "speech_dispatch": distribution(dispatch),
        "translation_execution": distribution(translations),
        "capture_callback_delay": distribution(capture_delay),
        "first_source_to_translation_ms": (
            round((first_translation - first_source) * 1000, 3)
            if first_source is not None and first_translation is not None else None
        ),
        "final_results": sum(event.get("final", 0) for event in events if event["stage"] == "speech.result"),
        "board_rewrites": {
            stage: (sum(event.get("rewrite", 0) for event in events if event["stage"] == stage)
                    if stages[stage] else None)
            for stage in ("board.source", "board.translation")
        },
        "boundaries": [
            "발화 시작부터의 지연이나 화면의 실제 렌더링 완료 시간을 측정하지 않는다.",
            "source-to-translation은 최초 인식된 임시 원문과 최초 번역의 간격이다.",
            "동일한 음성 파일, 설정, 빌드 구성으로 수집한 로그끼리 비교한다.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    prefix = "AIRTRANSLATE_LATENCY "
    events = []
    with args.trace.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            if not line.startswith(prefix):
                continue
            event = json.loads(line[len(prefix):])
            if isinstance(event.get("stage"), str) and isinstance(event.get("uptime"), (float, int)):
                events.append(event)
    if not events:
        parser.error("측정 이벤트가 없습니다. AIRTRANSLATE_LATENCY_TRACE=1로 앱을 실행해 수집하세요.")
    print(json.dumps(summarize(events), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
