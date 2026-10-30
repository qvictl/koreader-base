# koreader-base 维护与交付报告（2026-10-29）

证据快照：2026-10-29 17:30 UTC；报告整理：2026-10-30 UTC。

本轮 base 开发子任务已结束，确认的修复、回归和 CI 改造已合入。
本报告记录发布使用的精确版本，不表示全库 bug 清零或 Kindle 原 811 章卡死已解决。
三仓总报告见 [KOReader 维护报告](https://github.com/qvictl/koreader/blob/db52bf904ff246ccafee89cd0f542a2e9262fa9b/doc/reports/2026-10-29-maintenance.md)。

## 版本与修复

本轮主线终点为 `0cdffb07f88b58ea8d7684c30faa3db0a4adf5f4`。
KOReader 本次产品固定的是 `7c4e2f0d81afafb8a19dfa2a28ec2df461962272`，
不是主线终点；其后 [#33](https://github.com/qvictl/koreader-base/pull/33) 是恢复既有上游同步 diff 门槛例外，没有新运行时代码。

| 问题 | 已交付结果 | PR |
| --- | --- | --- |
| 归档错误与特殊数字序列化 | 保留归档错误，正确处理非十进制配置下的特殊数字，并回移稳定线 | [#23](https://github.com/qvictl/koreader-base/pull/23)、[#24](https://github.com/qvictl/koreader-base/pull/24) |
| macOS 网络平台判断 | 使用 LuaJIT 实际的 OSX 平台标识 | [#25](https://github.com/qvictl/koreader-base/pull/25) |
| 原生字体生命周期 | 文档 view 销毁后释放字体，产品固定 CREngine `b9d1feff0e68ebbf61784bc9c4d1d6dd81f5bcaa` | [#26](https://github.com/qvictl/koreader-base/pull/26) |
| worker 结果管道 | 部分输出、继承 writer、精确回收与取消路径不再依赖阻塞式整管道读取 | [#27](https://github.com/qvictl/koreader-base/pull/27) |
| 文件操作失败 | 保留并传播实际执行失败 | [#28](https://github.com/qvictl/koreader-base/pull/28) |
| shell 输出与取消 | 提供直接 exec 的 shell 输出管道，供上层响应式收集使用 | [#29](https://github.com/qvictl/koreader-base/pull/29) |
| 稳定分支 | 回移非阻塞命令和子进程 Lua 修复，稳定提交 `200cf0c9c52e028f0bc0eb9974af8fd590ed812a` | [#30](https://github.com/qvictl/koreader-base/pull/30) |

字体主机对照中，关闭后遗留 face 数从 6/5/7 变为 0，RSS 约少 16–18 MiB，18 张渲染 PNG 一致。
这是具体样本和生命周期结果，不能推导为 Kindle 固定收益、跨字号共用一个 face 或节省 40 MiB。
缩小 MuPDF store 的候选因样本渲染退化约 12% 已撤回。

## 完整测试与覆盖率

base 没有单独产品发行包。实测来自
[KOReader 发版 40918614215](https://github.com/qvictl/koreader/actions/runs/40918614215)，
由产品模拟器、base unit 统计和 SHA manifest 共同绑定上述精确 gitlink：

| 项目 | 结果 |
| --- | --- |
| 全量单测 | 37 suites、491 cases；0 failure、0 error、0 skip |
| 产品普通 IT | 28/28 scenarios，510/510 checks |
| 产品覆盖率 IT | 28/28 scenarios，510/510 checks |
| base unit | 41.580%，5,370/12,915 |
| base unit + integration | 45.833%，5,939/12,958 |
| 强制覆盖率门槛 | 6/6 通过，含独立 unit/combined 棘轮与 fork-owned 范围 |
| 本批执行行 diff | 0/0，没有新的生产执行行，不作为新增覆盖率成果 |

产品场景覆盖 archive/serialization、network info、异步结果、命令失败、流式输出及取消等真实调用链。
产品成功不等于所有平台的人工测试或 Kindle 真机回归完成。

## CI/CD

[#31](https://github.com/qvictl/koreader-base/pull/31)、[#32](https://github.com/qvictl/koreader-base/pull/32)、
[#33](https://github.com/qvictl/koreader-base/pull/33) 已合入：

- 普通 PR/main push 由完整改动范围和 base/head 两版依赖图选择完整 UT 套件；native/build、框架、未知依赖等保守全量，文档允许显式 none。
- 保留 native 构建、FFI cdecl、bincheck、lint、测试策略和 diff unit ≥80%；既有上游同步例外要求真实提交归属证据。
- 普通合代码不构建上层 KOReader 或执行真实集成。部分 UT 不生成 whole baseline，不写全量历史或徽章。
- 产品发布跑完整 base UT 与真实 IT，并检查精确 SHA、原 unit/combined 棘轮、diff80/90 和日期/模块目标；没有降低阈值。
- 原 protected-main、当前 head AI 审查及 review thread gate 保留，无额外人工关卡。

具体规则以 [CONTRIBUTING](../../CONTRIBUTING.md) 为准。本报告的文档提交不改变已验证产品 gitlink。

## overlay、设备与剩余工作

v2026.07.1 overlay 中的 8 个 base 文件按原构建脚本三方来源验证：
从 fork base `cd173c179a56b42ddbf06b6ac3eafec099ffe219` 到产品 base `7c4e2f0d` 的补丁，
应用于 release base `6e4bc81af4e04f78d81677a323a780a71b29702a`。
这不是完整复制 `kindle-v2026.07.1` 分支；overlay 也不含本轮原生字体二进制修复。

截至最后一次授权 USB 安装记录，Oasis 3 为此前 `938e5d52` 完整 HF 加插件 1.6.91；本文快照中的公开产品 `ab190e63` 未由本次维护重新安装。
原目录已有完整备份、安装文件/原配置 SHA 核验和安全卸载记录。
未完成的重点是 811 章卡死/OOM/COW 真机因果、长书和休眠恢复验收，以及按真实缺陷继续补齐覆盖率。
socket 报错不足以单独证明 Wi-Fi 状态缓存根因，不能将未证假设标为已修复。
