from flask import Flask, render_template, jsonify
import json
import re

app = Flask(__name__)

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/report')
def report():
    try:
        with open('../results/checklist_isms.json', encoding='utf-8') as f:
            isms = json.load(f)
    except:
        isms = []

    try:
        with open('../results/checklist_csap.json', encoding='utf-8') as f:
            csap = json.load(f)
    except:
        csap = []

    return render_template('report.html', isms=isms, csap=csap)

@app.route('/kube-bench')
def kube_bench():
    try:
        with open('../results/checklist_kubebench.json', encoding='utf-8') as f:
            result = json.load(f)
    except:
        result = {"개요": "불러오기 실패", "통계": {}, "주요_위험_항목": [], "긴급_대응_필요": []}
    개요 = result.get("개요", "")
    노드수_match = re.search(r"총\s*(\d+)\s*개의 노드", 개요)
    노드수 = int(노드수_match.group(1)) if 노드수_match else 3
    return render_template('kube_bench.html', title="Kube-Bench 결과", 노드수=노드수, **result)

@app.route('/kubescape')
def kubescape():
    try:
        with open('../results/checklist_kubescape.json', encoding='utf-8') as f:
            result = json.load(f)
    except:
        result = {"error": "파일을 불러올 수 없습니다."}
    return render_template('kubescape.html', title="Kubescape 결과", result=result)

@app.route('/grype')
def grype():
    try:
        with open('../results/checklist_grype.json', encoding='utf-8') as f:
            result = json.load(f)
    except:
        result = {"error": "파일을 불러올 수 없습니다."}
    return render_template('grype.html', title="Grype 취약점 결과", result=result)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
