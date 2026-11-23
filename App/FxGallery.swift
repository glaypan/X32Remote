import Foundation
import UIKit

/// 效果器图鉴（v1.8）。
///
/// 数据来自 `X32Simulator/tools/export_fx_gallery.py` 导出的 `Resources/fx/fxlib.json`，
/// 图片是**真机界面截图**：X32 侧由官方编辑器 X32-Edit 4.4 离线模式逐算法渲染后截取，
/// WING 侧取自官方手册站的 FX 选择页。图片只用来「认这是哪个效果器」，不参与任何参数运算。
///
/// 资源以「文件夹引用」整目录打进 bundle（`X32 Remote.app/fx/…`），
/// 目录结构与 JSON 里的 `img` 字段一致（`x32/HALL.webp`、`wing/premium/hall-reverb.webp`），
/// 所以取图只需 `root + img`。
final class FxGallery {
    static let shared = FxGallery()

    /// 一条图鉴条目。X32 侧有 code/cn/en/cat/n/heavy，WING 侧只有 slug/name，
    /// 合成一个结构省得三端各写一套解析。
    struct Item: Decodable, Identifiable {
        var code: String?
        var slug: String?
        var cn: String?
        var en: String?
        var name: String?
        var cat: String?
        var catCn: String?
        var n: Int?
        var heavy: Int?
        var img: String

        var id: String { code ?? slug ?? img }
        /// 主标题（X32 用中文名，WING 用真台英文名）
        var title: String { cn ?? name?.capitalized ?? code ?? slug ?? img }
        /// 副标题（真台面板上印的英文名）
        var subtitle: String? {
            if let en, en != title { return en }
            if let name, name != title { return name }
            return nil
        }
        /// 右下角小标签
        var tag: String? {
            if heavy == 1 { return "仅 FX1-4" }
            if let n, n > 0 { return "\(n) 参数" }
            return nil
        }
        var isHeavy: Bool { heavy == 1 }
    }

    struct Group: Identifiable {
        let id: String
        let title: String        // 分段控件上的短名
        let label: String        // JSON 里的完整说明
        let items: [Item]
    }

    private struct Raw: Decodable {
        struct X32: Decodable {
            let label: String
            let count: Int
            let items: [Item]
        }
        struct Wing: Decodable {
            let label: String
            let items: [Item]
        }
        let v: Int
        let note: String?
        let x32: X32
        let wing: [String: Wing]
    }

    /// 图鉴分组，顺序固定：X32 → WING 高级 → WING 标准
    let groups: [Group]
    private let x32ByCode: [String: Item]
    private var cache: [String: UIImage] = [:]

    var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }

    private init() {
        var groups: [Group] = []
        var byCode: [String: Item] = [:]

        let raw: Raw? = {
            guard let url = FxGallery.bundleRoot?.appendingPathComponent("fxlib.json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Raw.self, from: data)
        }()

        if let raw {
            groups.append(Group(id: "x32",
                                title: "X32 / M32",
                                label: raw.x32.label,
                                items: raw.x32.items))
            for it in raw.x32.items {
                if let c = it.code { byCode[c] = it }
            }
            // 预置顺序优先，未知组按字母序追加（WING 以后加组也不会掉）
            for (key, short) in [("premium", "WING 高级"), ("standard", "WING 标准")] {
                guard let g = raw.wing[key] else { continue }
                groups.append(Group(id: key, title: short, label: g.label, items: g.items))
            }
            for key in raw.wing.keys.sorted() where !["premium", "standard"].contains(key) {
                let g = raw.wing[key]!
                groups.append(Group(id: key, title: key.uppercased(), label: g.label, items: g.items))
            }
        }
        self.groups = groups
        self.x32ByCode = byCode
    }

    // MARK: - 取图

    /// bundle 里 `fx/` 目录（文件夹引用，整目录拷贝，结构原样保留）
    private static var bundleRoot: URL? {
        Bundle.main.resourceURL
    }

    /// 按 JSON 的 `img` 相对路径取图；缺图返回 nil（界面就只显示文字）。
    func image(_ rel: String) -> UIImage? {
        if let hit = cache[rel] { return hit }
        guard let url = FxGallery.bundleRoot?.appendingPathComponent("fx/\(rel)"),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache[rel] = img
        return img
    }

    /// 按真台算法枚举名取面板图（FX 槽卡片用）
    func image(x32Code: String?) -> UIImage? {
        guard let code = x32Code, let item = x32ByCode[code] else { return nil }
        return image(item.img)
    }

    /// 按真台算法枚举名取条目（详情页标题用）
    func item(x32Code: String?) -> Item? {
        guard let code = x32Code else { return nil }
        return x32ByCode[code]
    }
}
