#!/bin/bash

# 一键升级 x-ui 和 s-ui 面板脚本
# 用法: 保存为 update_panels.sh，然后 chmod +x update_panels.sh && ./update_panels.sh

echo "=== 开始检测和升级面板 ==="

# 初始化结果变量
xui_detected=false
xui_updated=false
sui_detected=false
sui_updated=false

# 检测并升级 x-ui
if command -v x-ui >/dev/null 2>&1; then
    xui_detected=true
    echo "检测到 x-ui 已安装，开始升级..."
    echo -e "y\n\n0" | x-ui update
    result=$?
    if [ $result -eq 0 ]; then
        xui_updated=true
        echo "x-ui 升级成功！"
    else
        echo "x-ui 升级失败（退出码: $result）"
    fi
else
    echo "未检测到 x-ui，未安装或不在 PATH 中，跳过。"
fi

echo ""  # 空行分隔

# 检测并升级 s-ui
if command -v s-ui >/dev/null 2>&1; then
    sui_detected=true
    echo "检测到 s-ui 已安装，开始升级..."
    echo -e "y\nn" | s-ui update
    result=$?
    if [ $result -eq 0 ]; then
        sui_updated=true
        echo "s-ui 升级成功！"
    else
        echo "s-ui 升级失败（退出码: $result）"
    fi
else
    echo "未检测到 s-ui，未安装或不在 PATH 中，跳过。"
fi

echo ""  # 空行分隔
echo "=== 升级总结 ==="
echo "x-ui 检测结果: $(if [ "$xui_detected" = true ]; then echo "已安装"; else echo "未安装"; fi)"
if [ "$xui_detected" = true ]; then
    echo "x-ui 升级结果: $(if [ "$xui_updated" = true ]; then echo "成功"; else echo "失败"; fi)"
fi

echo "s-ui 检测结果: $(if [ "$sui_detected" = true ]; then echo "已安装"; else echo "未安装"; fi)"
if [ "$sui_detected" = true ]; then
    echo "s-ui 升级结果: $(if [ "$sui_updated" = true ]; then echo "成功"; else echo "失败"; fi)"
fi

if [ "$xui_updated" = true ] || [ "$sui_updated" = true ]; then
    echo "总体升级: 至少一个面板升级成功。"
else
    echo "总体升级: 无成功升级（可能未安装或升级失败）。"
fi

echo "=== 结束 ==="

# 新增：JSON格式总结（用于批量解析）
json_summary='{"xui_detected": "'$xui_detected'", "xui_updated": "'$xui_updated'", "sui_detected": "'$sui_detected'", "sui_updated": "'$sui_updated'"}'
echo "$json_summary"
