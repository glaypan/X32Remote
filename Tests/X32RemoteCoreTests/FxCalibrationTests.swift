import XCTest
@testable import X32RemoteCore

/// 效果库标定表 (随 App 内嵌的 JSON) 的解码与查询测试。
/// 数据源与断言口径和模拟器端 test_fx.py A 层保持一致 —— 三端看同一份标定。
final class FxCalibrationTests: XCTestCase {

    private var lib: FxLib!

    override func setUpWithError() throws {
        lib = try XCTUnwrap(FxCalibrationStore.shared, "内嵌 JSON 解码失败")
    }

    // MARK: - 整体形状

    func testLibShape() {
        XCTAssertEqual(lib.version, 1)
        XCTAssertEqual(lib.algos.count, 61, "61 种算法一个不能少")
        let total = lib.algos.values.reduce(0) { $0 + $1.n }
        XCTAssertEqual(total, 886, "参数总数")
        XCTAssertEqual(lib.enum58.count, 34, "FX 5-8 可装的轻量子集")
        XCTAssertEqual(lib.catLabel.count, 9, "9 个分类")
    }

    /// 标定表自洽: 每种算法 n == params.count, par 从 1 连续, field 唯一,
    /// 枚举参数必须有 opts 且 lo/hi 覆盖下标范围。
    func testCalibrationSelfConsistent() {
        for (name, algo) in lib.algos {
            XCTAssertEqual(algo.n, algo.params.count, "\(name) 的 n 与 params 不符")
            for (i, p) in algo.params.enumerated() {
                XCTAssertEqual(p.p, i + 1, "\(name) 的 par 号不连续")
                XCTAssertFalse(p.field.isEmpty, "\(name) par\(p.p) field 为空")
                XCTAssertFalse(p.label.isEmpty, "\(name) par\(p.p) 缺中文名")
                XCTAssertLessThanOrEqual(p.lo, p.hi, "\(name) par\(p.p) 量程反了")
                if p.isEnum {
                    XCTAssertNotNil(p.opts, "\(name) par\(p.p) 是枚举但没有选项")
                    if let opts = p.opts {
                        XCTAssertGreaterThan(opts.count, 1)
                        XCTAssertEqual(Int(p.lo), 0)
                        XCTAssertEqual(Int(p.hi), opts.count - 1,
                                       "\(name) par\(p.p) 枚举量程和选项数不符")
                    }
                }
            }
            let fields = algo.params.map(\.field)
            XCTAssertEqual(Set(fields).count, fields.count, "\(name) 的 field 有重复")
        }
    }

    // MARK: - 修正后的关键映射 (旧标定把 HALL 的 par01/par02 搞反过)

    func testHallParamMapping() {
        let hall = try! XCTUnwrap(lib.algo("HALL"))
        let p1 = try! XCTUnwrap(hall.params.first { $0.p == 1 })
        XCTAssertEqual(p1.field, "pre_delay")
        XCTAssertEqual(p1.label, "预延迟")
        XCTAssertEqual(p1.unit, "ms")
        XCTAssertEqual(p1.lo, 0)
        XCTAssertEqual(p1.hi, 200)

        let p2 = try! XCTUnwrap(hall.params.first { $0.p == 2 })
        XCTAssertEqual(p2.field, "decay")
        XCTAssertEqual(p2.label, "混响时间")
        XCTAssertEqual(p2.lo, 0.2)
        XCTAssertEqual(p2.hi, 5.0)

        // Damping 是频率 (1k–20k Hz), 不是 0-1 的比例
        let p4 = try! XCTUnwrap(hall.params.first { $0.p == 4 })
        XCTAssertEqual(p4.field, "damping")
        XCTAssertEqual(p4.unit, "Hz")
        XCTAssertEqual(p4.lo, 1000)
        XCTAssertEqual(p4.hi, 20000)

        // 语义别名 → par 号 (Tap/同步组换算用)
        XCTAssertEqual(hall.time, 2)
        XCTAssertEqual(hall.predelay, 1)
        XCTAssertEqual(hall.damp, 4)
        XCTAssertEqual(hall.tunit, "s")
    }

    // MARK: - field → par 三条路径

    func testFieldToPar() {
        XCTAssertEqual(lib.fieldToPar("HALL", "decay"), 2, "算法 field 路径")
        XCTAssertEqual(lib.fieldToPar("HALL", "par02"), 2, "parNN 直址路径")
        XCTAssertEqual(lib.fieldToPar("HALL", "time"), 2, "语义别名 time")
        XCTAssertEqual(lib.fieldToPar("HALL", "predelay"), 1)
        XCTAssertEqual(lib.fieldToPar("HALL", "damp"), 4)
        XCTAssertNil(lib.fieldToPar("HALL", "par99"), "越界 parNN")
        XCTAssertNil(lib.fieldToPar("HALL", "no_such_field"))
        XCTAssertNil(lib.fieldToPar("NO_SUCH_ALGO", "decay"), "未知算法一律 nil")
    }

    // MARK: - 槽位约束 (heavy 仅 FX 1-4)

    func testSlotAllows() {
        XCTAssertTrue(lib.slotAllows(1, "HALL"))
        XCTAssertTrue(lib.slotAllows(4, "HALL"))
        XCTAssertFalse(lib.slotAllows(5, "HALL"), "heavy 算法进不了 FX5")
        XCTAssertFalse(lib.slotAllows(8, "HALL"))
        XCTAssertTrue(lib.slotAllows(5, "GEQ"), "GEQ 是轻量算法, 哪都能装")
        XCTAssertFalse(lib.slotAllows(5, "NO_SUCH_ALGO"))

        // enum58 全集必须都能装进 5-8 (真台约束的镜像)
        for name in lib.enum58 {
            for slot in 5...8 {
                XCTAssertTrue(lib.slotAllows(slot, name), "\(name) 应允许 FX\(slot)")
            }
        }
        // heavy 数量对上半数 (27 种 heavy, 34 种轻量)
        let heavy = lib.algos.values.filter { $0.heavy }
        XCTAssertEqual(heavy.count, 27)
    }

    // MARK: - clamp / display

    func testClamp() {
        let decay = try! XCTUnwrap(lib.paramSpec("HALL", "decay"))
        XCTAssertEqual(decay.clamp(3.5), 3.5)
        XCTAssertEqual(decay.clamp(10), 5.0, "超上界钳到 hi")
        XCTAssertEqual(decay.clamp(-1), 0.2, "超下界钳到 lo")
        // NaN / ±inf 一律先落 0 再钳进量程 —— 与服务端 fx_par_clamp 逐点一致。
        // 刻意不让 +inf 去 hi: 非有限值是"脏数据", 语义是回中性别 extrapolate,
        // 三端 (服务端/网页/iOS) 必须同一个答案, 否则同一份状态三处显示不同。
        XCTAssertEqual(decay.clamp(.nan), 0.2, "NaN → 0 → 钳到 lo")
        XCTAssertEqual(decay.clamp(.infinity), 0.2, "+inf 不 extrapolate 到 hi, 同走 0")
        XCTAssertEqual(decay.clamp(-.infinity), 0.2)

        let factor = try! XCTUnwrap(lib.paramSpec("3TAP", "factor_a"))
        XCTAssertTrue(factor.isEnum)
        XCTAssertEqual(factor.clamp(2.6), 3, "枚举四舍五入到整数下标")
        XCTAssertEqual(factor.clamp(-5), 0)
    }

    func testDisplay() {
        let decay = try! XCTUnwrap(lib.paramSpec("HALL", "decay"))
        XCTAssertEqual(decay.decimals, 2, "小量程两位小数")
        XCTAssertEqual(decay.display(2.4), "2.40 s")

        let damp = try! XCTUnwrap(lib.paramSpec("HALL", "damping"))
        XCTAssertEqual(damp.decimals, 0, "大量程不显示小数")
        XCTAssertEqual(damp.display(4000), "4000 Hz")

        let factor = try! XCTUnwrap(lib.paramSpec("3TAP", "factor_a"))
        XCTAssertEqual(factor.display(1), "3/8", "枚举按下标取中文/分数选项")
        XCTAssertEqual(factor.display(0), "1/4")
    }

    // MARK: - 旧名迁移

    func testAlias() {
        XCTAssertEqual(lib.alias["PLATE"], "PLAT")
        XCTAssertEqual(lib.alias["CHAMBER"], "CHAM")
        XCTAssertEqual(lib.alias["VINTAGE"], "VREV")
        // 新名自身必须在库里, 旧名不在
        XCTAssertNotNil(lib.algo("PLAT"))
        XCTAssertNil(lib.algo("PLATE"))
    }

    // MARK: - 分类分组

    func testAlgosByCategory() {
        let groups = lib.algosByCategory()
        XCTAssertEqual(groups.count, 9)
        let total = groups.reduce(0) { $0 + $1.names.count }
        XCTAssertEqual(total, 61, "分组合计必须覆盖全部算法")
        for g in groups {
            XCTAssertFalse(g.label.isEmpty)
            XCTAssertFalse(g.names.isEmpty)
            for name in g.names {
                XCTAssertEqual(lib.algo(name)?.cat, g.cat, "\(name) 分错组了")
            }
        }
        // 组内按名字排序 (界面稳定)
        for g in groups {
            XCTAssertEqual(g.names, g.names.sorted())
        }
    }
}
