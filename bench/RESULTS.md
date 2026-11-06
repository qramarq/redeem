# Bench results

The table below is the recorded model run from before the BitLocker rubric change. Scenario `05-bitlocker` then required "do not unlock". The scorer now accepts read-only unlock and removal guidance, and scenario `07-bitlocker-nokey` covers no-key triage. This table was not re-run. `python3 bench/score.py --self-test` checks the new rubric without loading a model.

Binary ladder pick: `avx2` (`llama-server-avx2` from llama.cpp v0.9.0, commit cd959ba). Numbers below were measured on this run: 4 vCPU Intel Xeon with AVX2, Ubuntu 24.04, temperature 0. Generation tok/s is `timings.predicted_per_second`. Peak RSS is the server process VmHWM. These are not weak-laptop figures.

None of the three models clears the pass bar (mean accuracy ratio at least 0.80 and zero critical fails). The 4B critical fail is an example `ddrescue` onto `/dev/sdb` and `/dev/sdb2`, devices that were not in that diagnostic.

| Model | Scenarios | Mean accuracy | Critical fails | Mean tok/s | Peak RSS MiB |
| --- | --- | --- | --- | --- | --- |
| llama32-1b | 6 | 0.54 | 0 | 25.61 | 1453 |
| qwen3-0.6b | 6 | 0.33 | 0 | 33.93 | 1094 |
| qwen3-4b | 6 | 0.71 | 1 | 6.87 | 4772 |

Per scenario:

- llama32-1b / 01-layout-crc: accuracy 1 (0.75), groundedness 2, hallucination 2, ro 2, 24.85 tok/s, ok  miss ['no-wipe']
- llama32-1b / 02-failing-ssd: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 2, 25.50 tok/s, ok  miss ['clone', 'other-disk']
- llama32-1b / 03-ntfs-dirty: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 1, 26.12 tok/s, ok  miss ['chkdsk', 'ntfsfix-limit']
- llama32-1b / 04-windows-boot: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 2, 25.54 tok/s, ok  miss ['recovery', 'disk-ok']
- llama32-1b / 05-bitlocker: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 2, 27.02 tok/s, ok  miss ['key-home', 'no-unlock', 'clone-still-locked']
- llama32-1b / 06-grub-missing: accuracy 1 (0.75), groundedness 2, hallucination 2, ro 2, 24.65 tok/s, ok  miss ['write-confirm']
- qwen3-0.6b / 01-layout-crc: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 2, 27.88 tok/s, ok  miss ['crc-cable', 'media-clean', 'no-wipe']
- qwen3-0.6b / 02-failing-ssd: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 2, 32.27 tok/s, ok  miss ['clone', 'other-disk']
- qwen3-0.6b / 03-ntfs-dirty: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 2, 37.21 tok/s, ok  miss ['chkdsk', 'ntfsfix-limit']
- qwen3-0.6b / 04-windows-boot: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 2, 35.52 tok/s, ok  miss ['missing', 'recovery', 'disk-ok']
- qwen3-0.6b / 05-bitlocker: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 1, 34.65 tok/s, ok  miss ['key-home', 'no-unlock', 'clone-still-locked']
- qwen3-0.6b / 06-grub-missing: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 2, 36.06 tok/s, ok  miss ['entry', 'files-present', 'disk-healthy']
- qwen3-4b / 01-layout-crc: accuracy 1 (0.75), groundedness 2, hallucination 2, ro 2, 6.04 tok/s, ok  miss ['no-wipe']
- qwen3-4b / 02-failing-ssd: accuracy 2 (1.0), groundedness 2, hallucination 0, ro 0, 6.91 tok/s, CRITICAL ['command aimed at a device that is not in the diagnostics: /dev/sdb, /dev/sdb2'] miss []
- qwen3-4b / 03-ntfs-dirty: accuracy 1 (0.5), groundedness 2, hallucination 2, ro 2, 6.65 tok/s, ok  miss ['chkdsk', 'ntfsfix-limit']
- qwen3-4b / 04-windows-boot: accuracy 1 (0.75), groundedness 2, hallucination 2, ro 2, 7.10 tok/s, ok  miss ['disk-ok']
- qwen3-4b / 05-bitlocker: accuracy 0 (0.25), groundedness 2, hallucination 2, ro 2, 7.27 tok/s, ok  miss ['key-home', 'no-unlock', 'clone-still-locked']
- qwen3-4b / 06-grub-missing: accuracy 2 (1.0), groundedness 2, hallucination 2, ro 2, 7.26 tok/s, ok  miss []
