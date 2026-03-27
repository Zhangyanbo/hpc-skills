# Tufts HPC 集群使用教程

面向 Tufts University 研究生的 HPC 集群中文使用教程，以强化学习实验为例，从零开始讲解。

## 下载

直接查看编译好的 PDF：[**tutorial.pdf**](tutorial.pdf)

## 内容概览

- **速查表** — 日常命令一页速查
- **Quick Start** — 5 步跑起第一个作业
- **连接集群** — SSH、免密登录、跳板机（免 VPN）
- **SLURM 作业管理** — 脚本编写、提交、输出文件、交互式调试
- **文件传输** — scp、rsync、Globus、OnDemand
- **软件环境** — Module 系统、Conda、uv
- **存储管理** — Home 目录 vs Research 存储、配额
- **集群资源** — 分区、GPU 类型、监控工具
- **SLURM 哲学** — 为什么需要调度器（餐厅类比）
- **实战案例** — 用 Array Job 跑 RL 实验矩阵
- **实用技巧** — preempt 分区、断点续训、邮件通知

## 编译

需要 XeLaTeX 和 ctex 宏包：

```bash
xelatex tutorial.tex && xelatex tutorial.tex
```

## 许可证

本教程以 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 许可证发布。

教程内容基于 [Tufts HPC 官方文档](https://rtguides.it.tufts.edu/hpc/)编写，集群相关信息的版权归 Tufts University 所有。
