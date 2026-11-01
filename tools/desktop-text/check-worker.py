#!/usr/bin/env python3
"""Real native text checks, exclusively committed synthetic content."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

STATE = {"stage": "setup", "completed": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--tokenizer-executable', required=True)
    parser.add_argument('--vocabulary', required=True)
    parser.add_argument('--model')
    args = parser.parse_args()
    executable = Path(args.executable).resolve()
    model = Path(args.model).resolve() if args.model else None
    checks = 0

    def invoke(text='Synthetic content.', path=model, valid=True, raw=None, worker=executable):
        nonlocal checks
        data = raw if raw is not None else json.dumps({'text': text, 'task': 'enrichment',
                                                       'model': str(path) if path else None}).encode()
        result = subprocess.run([str(worker)], input=data, capture_output=True, timeout=20, cwd=tempfile.gettempdir())
        if result.stderr or len(result.stdout) > 4096:
            raise RuntimeError('Text worker diagnostic/output contract failed')
        if not valid:
            if result.returncode == 0 or result.stdout:
                raise RuntimeError('Invalid text worker request/asset was accepted')
            checks += 1
            STATE["completed"] = checks
            return None
        if result.returncode:
            raise RuntimeError('Native text worker failed')
        value = json.loads(result.stdout)
        if (set(value) != {'task', 'summary', 'language', 'entities', 'inputTruncated'} or
                value['task'] != 'enrichment' or value['summary'] is not None or
                not isinstance(value['inputTruncated'], bool) or not isinstance(value['entities'], list) or
                len(value['entities']) > 5 or any(not isinstance(x, str) or not x or x not in text or len(x.encode()) > 512 for x in value['entities'])):
            raise RuntimeError('Native text metadata/grounding contract failed')
        checks += 1
        STATE["completed"] = checks
        return value

    STATE['stage'] = 'tokenizer_reference'
    reference = json.loads(Path(__file__).with_name('tokenizer-reference.json').read_text(encoding='utf-8'))['cases']
    result = subprocess.run([str(Path(args.tokenizer_executable).resolve()), str(Path(args.vocabulary).resolve())],
                            input=json.dumps([case['text'] for case in reference]).encode(), capture_output=True, timeout=15)
    expected = [{key: value for key, value in case.items() if key != 'text'} for case in reference]
    if result.returncode or result.stderr or json.loads(result.stdout) != expected:
        raise RuntimeError('Native token IDs/original UTF-8 offsets differ from the independent reference')
    checks += len(reference)
    STATE["completed"] = checks
    texts = {
        'en': 'The research center invited local engineers to discuss a new investment project. The group reviewed the current schedule and agreed to continue the technical discussion next week.',
        'zh-Hans': '微软首席执行官在北京宣布了新的研发计划。这家公司将支持工程师开展人工智能技术研究，并且为当地客户提供更好的服务。该计划预计将在明年开始实施，同时邀请其他企业和大学参与合作。',
        'zh-Hant': '微軟執行長在臺北宣布了新的研發計畫。這家公司將支持工程師開展人工智慧技術研究，並且為當地客戶提供更好的服務。該計畫預計將在明年開始實施，同時邀請其他企業和大學參與合作。',
        'ja': 'ソニーは東京都で新しい研究計画を発表した。同社は来年から技術開発を進め、地元の大学と協力して新製品を開発する予定だ。新しい取り組みは地域の雇用にも貢献すると説明した。',
        'ko': '삼성전자는 서울에서 새로운 연구 계획을 발표했다. 회사는 내년부터 기술 개발을 진행하고 지역 대학과 협력하여 새로운 제품을 개발할 예정이다. 새로운 계획은 지역 일자리에도 도움이 될 것이라고 설명했다.',
        'de': 'Das Unternehmen hat in Berlin einen neuen Forschungsplan vorgestellt. Im kommenden Jahr beginnt die technische Entwicklung gemeinsam mit örtlichen Universitäten. Das Projekt soll zusätzliche Arbeitsplätze schaffen.',
        'es': 'La empresa presentó en Madrid un nuevo plan de investigación. El próximo año comenzará el desarrollo técnico junto con las universidades locales. El proyecto también creará nuevos empleos en la región.',
    }
    for code, text in texts.items():
        STATE["stage"] = "language_" + code
        value = invoke(text, path=None)
        if value['language'] != code or value['entities'] or value['inputTruncated']:
            raise RuntimeError('Native language/script identification differs from the synthetic reference')
    STATE['stage'] = 'input_refusal'
    for raw in (b'', b'{}', b'{', b'x' * (512 * 1024 + 1),
                json.dumps({'text': '', 'task': 'enrichment', 'model': None}).encode(),
                json.dumps({'text': 'x' * 65537, 'task': 'enrichment', 'model': None}).encode(),
                json.dumps({'text': 'Synthetic', 'task': 'summary', 'model': None}).encode()):
        invoke(raw=raw, valid=False)
    STATE['stage'] = 'asset_refusal'
    with tempfile.TemporaryDirectory(prefix='private-native-text-') as temporary:
        root = Path(temporary)
        for target in (root / 'missing.onnx', root):
            invoke(path=target, valid=False)
        wrong = root / 'wrong-size.onnx'
        wrong.write_bytes(b'not a model')
        invoke(path=wrong, valid=False)
        if os.name != 'nt':
            fifo = root / 'model-fifo'
            os.mkfifo(fifo)
            invoke(path=fifo, valid=False)
        # The build output and system temporary directory may be different
        # filesystems. Own independent copies; cached model/assets stay intact.
        private = root / 'bundle 日本語'
        private.mkdir()
        for name in (executable.name, 'onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'libonnxruntime.so.1'):
            item = executable.parent / name
            if item.is_file():
                shutil.copy2(item, private / name)
        for name in ('clipboard-language-id.ftz', 'clipboard-text-vocab.txt'):
            shutil.copyfile(executable.parent / name, private / name)
        copied = invoke(texts['en'], path=None, worker=private / executable.name)
        if copied['language'] != 'en':
            raise RuntimeError('Unicode executable/resource directory did not preserve language identification')
        data = private / 'clipboard-language-id.ftz'
        with data.open('r+b') as stream:
            stream.write(b'BAD!')
        invoke(path=None, valid=False, worker=private / executable.name)
        if model:
            STATE["stage"] = "entity_inference_and_refusal"
            text = 'Apple Inc. CEO Tim Cook met officials in Tokyo to discuss the company investment. The meeting focused on the research center and jobs for local engineers.'
            value = invoke(text)
            if value['language'] != 'en' or not {'Apple Inc', 'Tim Cook', 'Tokyo'} <= set(value['entities']):
                raise RuntimeError('Named-entity reference failed')
            negative = invoke(texts['en'])
            if negative['entities']:
                raise RuntimeError('Common nouns were emitted as proper named entities')
            dates = invoke('On Monday, January 20, 2025, Tim Cook met officials in Tokyo to discuss a research investment. The planning meeting lasted three hours and focused on new jobs.')
            if not {'Tim Cook', 'Tokyo'} <= set(dates['entities']) or any(
                    'Monday' in value or 'January' in value or '2025' in value for value in dates['entities']):
                raise RuntimeError('Date labels entered the proper-name contract')
            chinese = invoke(texts['zh-Hans'])
            if not {'微软', '北京'} <= set(chinese['entities']):
                raise RuntimeError('Chinese entity reference failed')
            limited = invoke('Apple Inc. in Tokyo. ' + 'Synthetic context. ' * 1500)
            if not limited['inputTruncated']:
                raise RuntimeError('NER context truncation was hidden')
            same_size = root / 'same-size-invalid.onnx'
            with same_size.open('wb') as stream:
                stream.truncate(model.stat().st_size)
            invoke(path=same_size, valid=False)
            link = model.parent / ('private 模型 ' + root.name + '.onnx')
            try:
                os.link(model, link)
                invoke(text, path=link)
            finally:
                link.unlink(missing_ok=True)
            if os.name != 'nt':
                alias = root / 'model-symlink.onnx'
                alias.symlink_to(model)
                invoke(path=alias, valid=False)
            shutil.copyfile(executable.parent / 'clipboard-language-id.ftz', data)
            vocabulary = private / 'clipboard-text-vocab.txt'
            with vocabulary.open('r+b') as stream:
                stream.write(b'BAD!')
            invoke(path=model, valid=False, worker=private / executable.name)
        if os.name != 'nt':
            data.unlink()
            data.symlink_to(executable.parent / 'clipboard-language-id.ftz')
            invoke(path=None, valid=False, worker=private / executable.name)
    print(json.dumps({'native_text_checks': checks, 'passed': True, 'real_entity_inference': bool(model)}), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print(json.dumps({'native_text_checks': STATE['completed'], 'passed': False, 'stage': STATE['stage']}), flush=True)
        raise SystemExit('Native text checks failed')
