
# RunFilesBuilder 
- 24.10.x ✅
- 25.12.x ✅


【[ENGLISH](https://github.com/wukongdaily/RunFilesBuilder/blob/master/README_en.md)】

>> 这是一个工作流。同步各位大佬项目里最新编译的ipk文件 生成适用于iStoreOS/OpenWrt 用的run自解压包<br>
>> 本质上是利用makeslef,将ipk和shell文件打包成自解压程序。<br>
>> iStoreOS 可以在iStore商店手动安装<br>
>> ImmortalWrt或者其他OpenWrt 可下载后 使用 `sh xxx.run `来安装<br>
>> 使用 `sh xxx.run --target dir --noexec ` 只解压到dir目录 不执行安装



## run文件安装方法


## Install By Command
> Like This (Immortalwrt 等其他OpenWrt)
```bash
wget -O xxx.run <run下载地址>
sh xxx.run
```

## Immortalwrt 如何安装iStore商店
```
wget -qO imm.sh https://cafe.cpolar.top/wkdaily/zero3/raw/branch/main/zero3/imm.sh && chmod +x imm.sh && ./imm.sh

```


<details>
<summary><h2>🍭鸣谢和引用的项目 👇🏿</h2></summary>
  
> 【打包】https://github.com/megastep/makeself
> > 【引用】https://github.com/Openwrt-Passwall/openwrt-passwall<br>
> > 【引用】https://github.com/Openwrt-Passwall/openwrt-passwall2<br>
> > 【引用】https://github.com/vernesong/OpenClash<br>
> > 【引用】https://dl.openwrt.ai<br>
> > 【引用】https://github.com/morytyann/OpenWrt-mihomo/wiki<br>
> > 【引用】https://github.com/AdguardTeam/AdGuardHome/releases/latest<br>
> > 【引用】https://github.com/sbwml/luci-app-mosdns<br>
> > 【引用】https://downloads.immortalwrt.org


