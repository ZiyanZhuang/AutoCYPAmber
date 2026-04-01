#!/usr/bin/env bash
# =============================================================
# Day 1 自动验证脚本：CYP2A6 + Heme（无配体）
# 用法：bash scripts/linux/run_cyp2a6_day1.sh
# =============================================================
set -euo pipefail

WORK_DIR="$HOME/cyp2a6_validation"
ACYPA_DIR="$HOME/AutoCYPAmber"
BUILD_LOG="$HOME/amber_build.log"
AMBER_INSTALL="$HOME/amber_builds/current"

echo "======================================================"
echo " Step 1: 安装 ACYPA 包 + pyscf"
echo "======================================================"
cd "$ACYPA_DIR"
pip install -e . -q
pip install pyscf -q
echo ">>> ACYPA + pyscf 安装完成"

echo "======================================================"
echo " Step 2: 下载并预处理 CYP2A6 PDB (1MWQ)"
echo "======================================================"
mkdir -p "$WORK_DIR/inputs"
cd "$WORK_DIR/inputs"

if [ ! -f 1MWQ.pdb ]; then
    echo ">>> 下载 1MWQ.pdb ..."
    wget -q https://files.rcsb.org/download/1MWQ.pdb
    echo ">>> 下载完成"
else
    echo ">>> 1MWQ.pdb 已存在，跳过下载"
fi

# 保留 ATOM（蛋白）+ HETATM HEM，去除其他配体和水
grep -E "^ATOM|^HETATM.*[[:space:]]HEM[[:space:]]" 1MWQ.pdb > cyp2a6.pdb
echo ">>> PDB 预处理完成，原子数: $(grep -c '^ATOM\|^HETATM' cyp2a6.pdb)"

# 确认 Cys 编号
echo ">>> 末尾 CYS 残基（轴向 Cys 候选）："
grep "^ATOM.*CYS" cyp2a6.pdb | awk '{print $5, $6}' | sort -k2 -n | tail -5

echo "======================================================"
echo " Step 3: 等待 AMBER 编译完成..."
echo "======================================================"
while true; do
    if grep -q "Bootstrap finished" "$BUILD_LOG" 2>/dev/null; then
        echo ">>> AMBER 编译完成！"
        break
    fi
    if [ -f "$BUILD_LOG" ]; then
        LAST=$(tail -1 "$BUILD_LOG" 2>/dev/null || echo "")
        echo ">>> 编译中... $(date '+%H:%M:%S')  |  $LAST"
    else
        echo ">>> 等待编译日志出现... $(date '+%H:%M:%S')"
    fi
    sleep 60
done

echo "======================================================"
echo " Step 4: 激活 AMBER 环境"
echo "======================================================"
source "$ACYPA_DIR/scripts/linux/activate_autocypamber_runtime.sh"
echo ">>> 环境激活完成"

echo "======================================================"
echo " Step 5: 验证运行时环境"
echo "======================================================"
python3 - << 'PY'
from acypa.skills import skill_validate_runtime_environment
import json
report = skill_validate_runtime_environment(engine="sander")
print(json.dumps(report, indent=2, ensure_ascii=False))
if report["status"] != "success":
    print("ERROR: 环境验证失败，缺失:", report.get("missing"))
    raise SystemExit(1)
print(">>> 环境验证通过")
PY

echo "======================================================"
echo " Step 6: 运行 Heme 准备流程"
echo "======================================================"
python3 - << 'PY'
import os, sys
sys.path.insert(0, os.path.expanduser("~/AutoCYPAmber"))
from acypa.skills.amber_skills import skill_prepare_cyp_heme

result = skill_prepare_cyp_heme(
    pdb_path=os.path.expanduser("~/cyp2a6_validation/inputs/cyp2a6.pdb"),
    output_dir=os.path.expanduser("~/cyp2a6_validation/outputs/prep_heme"),
    axial_cys_resid=439,
    state=None
)
print("Heme 状态:", result.get("state"))
print("输出 PDB:", result.get("pdb"))
if not result.get("pdb"):
    raise SystemExit("Heme 准备失败")
PY

echo "======================================================"
echo " Step 7: 运行 tleap 建立拓扑"
echo "======================================================"
cd "$WORK_DIR/outputs/prep_heme"
tleap -f tleap.in > tleap_run.log 2>&1
if [ -f complex.prmtop ] && [ -f complex.inpcrd ]; then
    echo ">>> tleap 成功，拓扑文件已生成"
else
    echo "ERROR: tleap 失败，查看 tleap_run.log"
    tail -20 tleap_run.log
    exit 1
fi

echo "======================================================"
echo " Step 8: 运行短 MD（local_smoke, sander）"
echo "======================================================"
python3 - << 'PY'
import os, sys
sys.path.insert(0, os.path.expanduser("~/AutoCYPAmber"))
from acypa.simulation.amber_md import AmberMDRunner

runner = AmberMDRunner(
    work_dir=os.path.expanduser("~/cyp2a6_validation/outputs/md_run"),
    top_file=os.path.expanduser("~/cyp2a6_validation/outputs/prep_heme/complex.prmtop"),
    crd_file=os.path.expanduser("~/cyp2a6_validation/outputs/prep_heme/complex.inpcrd"),
    engine="sander",
    profile="local_smoke"
)
result = runner.run_protocol()
print("MD 状态:", result.get("status"))
if result.get("status") != "success":
    print("错误:", result.get("error"))
    raise SystemExit(1)
print("轨迹:", result.get("trajectory"))
PY

echo "======================================================"
echo " Step 9: 分析轨迹"
echo "======================================================"
python3 - << 'PY'
import os, sys, json
sys.path.insert(0, os.path.expanduser("~/AutoCYPAmber"))
from acypa.analysis import analyze_md_stability

result = analyze_md_stability(
    run_dir=os.path.expanduser("~/cyp2a6_validation/outputs"),
    prmtop_path=os.path.expanduser("~/cyp2a6_validation/outputs/prep_heme/complex.prmtop"),
    traj_path=os.path.expanduser("~/cyp2a6_validation/outputs/md_run/md_output/08.nc"),
    output_dir=os.path.expanduser("~/cyp2a6_validation/outputs/analysis"),
    config_path=os.path.expanduser("~/cyp2a6_validation/case_config.json")
)
print("分析状态:", result.get("status"))
if result.get("stats"):
    for k, v in result["stats"].items():
        print(f"  {k}: mean={v['mean']:.3f}, min={v['min']:.3f}, max={v['max']:.3f}")
PY

echo "======================================================"
echo " 全部完成！结果在 ~/cyp2a6_validation/outputs/"
echo "======================================================"
