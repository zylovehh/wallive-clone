# 壁纸目录：上新说明

App 的“目录”页每次打开都会拉取仓库根目录的 `catalog.json`，
所以上新壁纸不用重新发 App，只要传文件 + 改 `catalog.json`。

## 1. 传文件（都放 `wallpapers/` 目录）

一张壁纸需要三个文件：

- 壁纸包：`<名字>.tendies`（编辑器导出、真机测过能装上的）
- 预览视频：`<名字>-preview.mp4`（十几秒，录一段壁纸动起来的样子）
- 缩略图：`<名字>-thumb.jpg`（卡片上显示的静态图）

注意：单个文件走网页上传不能超 25MB；壁纸包一般就 1～2MB，预览视频压一下也都在范围内。

## 2. 改 `catalog.json`（仓库根目录）

在 `items` 里加一段，字段照着写：

```json
{
  "id": "four-seasons-tree",
  "title": "四季树",
  "tags": ["风景"],
  "thumbnail": "https://raw.githubusercontent.com/zyl.../wallive-clone/main/wallpapers/four-seasons-tree-thumb.jpg",
  "preview": "https://raw.githubusercontent.com/zyl.../wallive-clone/main/wallpapers/four-seasons-tree-preview.mp4",
  "package": "https://raw.githubusercontent.com/zyl.../wallive-clone/main/wallpapers/four-seasons-tree.tendies"
}
```

字段说明：

- `id`：唯一编号，只用字母、数字、下划线、横线（会用来当本地文件名）。
- `title`：卡片上显示的名字。
- `tags`：标签数组，分类筛选和搜索都用它。
- `thumbnail` / `preview` / `package`：上面三个文件的 raw 地址
  （`https://raw.githubusercontent.com/zyl.../wallive-clone/main/wallpapers/文件名`）。

## 3. 换掉示例条目

现在 `catalog.json` 里只有一个 `example` 示例条目（文件还不存在），
真实壁纸到了就把这一段删掉换成真的。
