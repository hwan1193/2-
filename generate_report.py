import argparse
import json
import requests

def call_gemini(api_key, json_file, prompt_file, output_file):
    with open(json_file, 'r') as jf, open(prompt_file, 'r') as pf:
        log_data = json.load(jf)
        prompt = pf.read()

    final_prompt = f"{prompt}\n\n[로그 데이터]\n{json.dumps(log_data, indent=2)}"

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent?key={api_key}"
    headers = {"Content-Type": "application/json"}
    body = {
        "contents": [{"parts": [{"text": final_prompt}]}]
    }

    response = requests.post(url, headers=headers, json=body)
    if response.status_code != 200:
        raise Exception(f"❌ Gemini API Error {response.status_code} - {response.text}")

    result_text = response.json()["candidates"][0]["content"]["parts"][0]["text"]

    # 코드블럭 감싸져 있으면 제거
    result_text = result_text.strip()
    if result_text.startswith("```json"):
        result_text = result_text.removeprefix("```json").removesuffix("```").strip()

    # 그냥 결과 그대로 저장 (파싱 없이)
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(result_text)

    # 디버깅 로그도 저장
    with open("auto_report/results/debug_gemini_raw.txt", "w", encoding="utf-8") as f:
        f.write(result_text)

    print(f"✅ 결과 저장 완료: {output_file}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--api_key', required=True)
    parser.add_argument('--json_file', required=True)
    parser.add_argument('--prompt_file', required=True)
    parser.add_argument('--output_file', required=True)
    args = parser.parse_args()

    print(" Gemini API 호출 중...")
    call_gemini(args.api_key, args.json_file, args.prompt_file, args.output_file)

if __name__ == '__main__':
    main()
