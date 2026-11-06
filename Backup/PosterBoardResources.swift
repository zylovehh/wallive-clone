// PosterBoardResources.swift
// 描述符版本目录里要换上的三份 `com.apple.posterkit.provider.instance.*` 配置 plist。
//
// 原样抄自 GoldenNugget 手机版 `Nugget/Core/PosterBoardResources.swift` 的
// `configConversion`（生成脚本 `scripts/gen-pb-resources-from-goldennugget.py`，
// 来源是桌面版 `files/posterboard`，共 37 个文件里与配置转换有关的三份）。
// 只抄了这三份：live-photo / 视频那堆 v1 用不上，不搬。
// base64 字面量一字未动——错一个字符，设备上的描述符就少一份配置。
// 核对：解码后三份的 SHA256 见 stage4/REPORT.md，复核时与源文件逐份对过。

import Foundation

enum PosterBoardResources {
    /// base64 解码，容忍字面量里的换行；解不出来直接崩——一个坏掉的字面量
    /// 绝不能以 0 字节载荷的面目送到设备上（商店会直接丢掉那个描述符）。
    private static func b64(_ value: String) -> Data {
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters),
              !data.isEmpty || value.isEmpty else {
            preconditionFailure("PosterBoardResources: a base64 literal did not decode")
        }
        return data
    }

    /// The three ``com.apple.posterkit.provider.instance.*`` plists that replace a tendie's
    /// own copies (``PBConfigManager.cache_config_files``).
    static let configConversion: [String: Data] = [
        "com.apple.posterkit.provider.instance.quickActions.plist":
            b64("""
            YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
            ctEICVRyb290gAGvEBILDBMbIyssLTQ1OT1BRktMTU5VJG51bGzTDQ4PEBESXxAPdHJhaWxpbmdDb250cm9sXmxlYWRpbmdD
            b250cm9sViRjbGFzc4ALgAKAEdQUFRYPFxgZGlhpZGVudGl0eVR0eXBlWGNhdGVnb3J5gAMQARADgArUHB0eDx8gISJZaW50
            ZW50UmVmVGtpbmRVZXh0SWSAAIAIgASACdQkJSYPHygpKl8QEGRldmljZUlkZW50aWZpZXJfEBljb250YWluZXJCdW5kbGVJ
            ZGVudGlmaWVyXxAZZXh0ZW5zaW9uQnVuZGxlSWRlbnRpZmllcoAAgAaABYAHXxA2Y29tLmFwcGxlLkNvbnRyb2xDZW50ZXIu
            Q29udHJvbENlbnRlckNvbnRyb2xzRXh0ZW5zaW9uXxAVY29tLmFwcGxlLnNwcmluZ2JvYXJk0i4vMDFaJGNsYXNzbmFtZVgk
            Y2xhc3Nlc18QFENIU0V4dGVuc2lvbklkZW50aXR5ojIzXxAUQ0hTRXh0ZW5zaW9uSWRlbnRpdHlYTlNPYmplY3RfEEFjb20u
            YXBwbGUuQ29udHJvbENlbnRlci5Db250cm9sQ2VudGVyQ29udHJvbHNFeHRlbnNpb24uZmxhc2hsaWdodNIuLzY3XxASQ0hT
            Q29udHJvbElkZW50aXR5ojgzXxASQ0hTQ29udHJvbElkZW50aXR50i4vOjtfECFQUlF1aWNrQWN0aW9uQ29udHJvbENvbmZp
            Z3VyYXRpb26iPDNfECFQUlF1aWNrQWN0aW9uQ29udHJvbENvbmZpZ3VyYXRpb27UFBUWDz4/GRqADBACgArUHB0eDx9DRCKA
            AIAQgA2ACdQkJSYPH0hJKoAAgA+ADoAHXxApY29tLmFwcGxlLmNhbWVyYS5MYXVuY2hlckNvbnRyb2xFeHRlbnNpb25fEBBj
            b20uYXBwbGUuY2FtZXJhXxAgY29tLmFwcGxlLmNhbWVyYS5kZWVwbGluay5idXR0b27SLi9PUF8QIVBSUG9zdGVyUXVpY2tB
            Y3Rpb25zQ29uZmlndXJhdGlvbqJRM18QIVBSUG9zdGVyUXVpY2tBY3Rpb25zQ29uZmlndXJhdGlvbgAIABEAGgAkACkAMgA3
            AEkATABRAFMAaABuAHUAhwCWAJ0AnwChAKMArAC1ALoAwwDFAMcAyQDLANQA3gDjAOkA6wDtAO8A8QD6AQ0BKQFFAUcBSQFL
            AU0BhgGeAaMBrgG3Ac4B0QHoAfECNQI6Ak8CUgJnAmwCkAKTArcCwALCAsQCxgLPAtEC0wLVAtcC4ALiAuQC5gLoAxQDJwNK
            A08DcwN2AAAAAAAAAgEAAAAAAAAAUgAAAAAAAAAAAAAAAAAAA5o=
            """),
        "com.apple.posterkit.provider.instance.renderingConfiguration.plist":
            b64("""
            YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
            ctEICVRyb290gAGjCwwTVSRudWxs0w0ODxAREF8QFW1vdGlvbkVmZmVjdHNEaXNhYmxlZFYkY2xhc3NfEBNkZXB0aEVmZmVj
            dERpc2FibGVkCIACCNIUFRYXWiRjbGFzc25hbWVYJGNsYXNzZXNfEB5QUlBvc3RlclJlbmRlcmluZ0NvbmZpZ3VyYXRpb26i
            GBlfEB5QUlBvc3RlclJlbmRlcmluZ0NvbmZpZ3VyYXRpb25YTlNPYmplY3QACAARABoAJAApADIANwBJAEwAUQBTAFcAXQBk
            AHwAgwCZAJoAnACdAKIArQC2ANcA2gD7AAAAAAAAAgEAAAAAAAAAGgAAAAAAAAAAAAAAAAAAAQQ=
            """),
        "com.apple.posterkit.provider.instance.titleStyleConfiguration.plist":
            b64("""
            YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
            ctEICVRyb290gAGvEBsLDC83ODlBQkNPUFRZZWtscHh5gYKDhIiLjI1VJG51bGzfEBENDg8QERITFBUWFxgZGhscHR4eICAi
            HiQeJicoKSkrLC0uXnVzZXJDb25maWd1cmVkXxAiaXNBZGFwdGl2ZVRpbWVIZWlnaHRVc2VyQ29uZmlndXJlZF8QGnByZWZl
            cnJlZFRpbWVNYXhZTGFuZHNjYXBlXxARY29udGVudHNMdW1pbmVuY2VXdmVyc2lvbl8QG3Blcm1hbmVudENvbXBhY3RUaW1l
            RW5hYmxlZF8QGmFkYXB0aXZlVGltZUNvbmZpZ3VyYXRpb25zXxAUYWx0ZXJuYXRlRGF0ZUVuYWJsZWRfEBFwcmVmZXJyZWRU
            aW1lTWF4WVp0aXRsZUNvbG9yXxATdGltZU51bWJlcmluZ1N5c3RlbV8QF3ByZWZlcnJlZFRpdGxlQWxpZ25tZW50XxAUcHJl
            ZmVycmVkVGl0bGVMYXlvdXRWJGNsYXNzWWdyb3VwTmFtZV8QEXRpdGxlQ29udGVudFN0eWxlXxAVdGltZUZvbnRDb25maWd1
            cmF0aW9uCAiAFIAUgA4IgBAIgBiACIAAgAaABoAagBmAB4AC1DAxMhozNDU2XxASdGltZUZvbnRJZGVudGlmaWVyXGlzU3lz
            dGVtSXRlbVZ3ZWlnaHSAAwmABIAFXxAYUFJUaW1lRm9udElkZW50aWZpZXJTb2Z0I0CEAAAAAAAA0jo7PD1aJGNsYXNzbmFt
            ZVgkY2xhc3Nlc18QI1BSUG9zdGVyU3lzdGVtVGltZUZvbnRDb25maWd1cmF0aW9uoz4/QF8QI1BSUG9zdGVyU3lzdGVtVGlt
            ZUZvbnRDb25maWd1cmF0aW9uXxAdUFJQb3N0ZXJUaW1lRm9udENvbmZpZ3VyYXRpb25YTlNPYmplY3QQAE8RAWBicGxpc3Qw
            MNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVHJv
            b3SAAaMLDBNVJG51bGzTDQ4PEBESViRjbGFzc1pmcm9zdExldmVsXxAVcHJlZmVycmVkTWF0ZXJpYWxUeXBlgAIjP+gAAAAA
            AAAQANIUFRYXWiRjbGFzc25hbWVYJGNsYXNzZXNfECNQUlBvc3RlckNvbnRlbnRWaWJyYW50TWF0ZXJpYWxTdHlsZaIYGV8Q
            I1BSUG9zdGVyQ29udGVudFZpYnJhbnRNYXRlcmlhbFN0eWxlWE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBXAF0A
            ZABrAHYAjgCQAJkAmwCgAKsAtADaAN0BAwAAAAAAAAIBAAAAAAAAABoAAAAAAAAAAAAAAAAAAAEM1kQaRUZHSCJKS0weTl5w
            cmVmZXJyZWRTdHlsZVljb2xvckRhdGFaaWRlbnRpZmllcllzdWdnZXN0ZWRVY29sb3KADoAPgAqACQiADF8QFHZpYnJhbnRN
            YXRlcmlhbENvbG9y0lEaUlNXTlMuZGF0YU8RAW1icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgk
            b2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVHJvb3SAAaMLDBlVJG51bGzWDQ4PEBESExQVFhcYXxAVVUlDb2xv
            ckNvbXBvbmVudENvdW50V1VJV2hpdGVXVUlBbHBoYVdOU1doaXRlXE5TQ29sb3JTcGFjZVYkY2xhc3MQAiI/gAAAIj8AAABF
            MSAwLjUQBIAC0xobHB0eIFokY2xhc3NuYW1lWCRjbGFzc2VzWyRjbGFzc2hpbnRzV1VJQ29sb3KiHR9YTlNPYmplY3ShIVdO
            U0NvbG9yAAgAEQAaACQAKQAyADcASQBMAFEAUwBXAF0AagCCAIoAkgCaAKcArgCwALUAugDAAMIAxADLANYA3wDrAPMA9gD/
            AQEAAAAAAAACAQAAAAAAAAAiAAAAAAAAAAAAAAAAAAABCYAL0jo7VVZdTlNNdXRhYmxlRGF0YaNXWEBdTlNNdXRhYmxlRGF0
            YVZOU0RhdGHWWltcXV4aX2BhYmNkXxAVVUlDb2xvckNvbXBvbmVudENvdW50V1VJV2hpdGVXVUlBbHBoYVdOU1doaXRlXE5T
            Q29sb3JTcGFjZRACIj+AAAAiPwAAAEUxIDAuNRAEgA3TOjtmZ2hpWyRjbGFzc2hpbnRzV1VJQ29sb3KiZ0ChaldOU0NvbG9y
            EALSOjttbl1QUlBvc3RlckNvbG9yom9AXVBSUG9zdGVyQ29sb3LTcXIac3V3V05TLmtleXNaTlMub2JqZWN0c6F0gBGhdoAS
            gBdfEBVESVNQTEFZX1RZUEVfRU1CRURERUTVGg96exF8IB5/gF8QIGFkYXB0aXZlVGltZUhlaWdodFVzZXJDb25maWd1cmVk
            XxAZcHJlZmVycmVkVGltZU1heFlQb3J0cmFpdIAWgBQIgBOAFSM/ziLBGgpqkCMAAAAAAAAAABAB0jo7hYZfECFQUlBvc3Rl
            ckFkYXB0aXZlVGltZUNvbmZpZ3VyYXRpb26ih0BfECFQUlBvc3RlckFkYXB0aXZlVGltZUNvbmZpZ3VyYXRpb27SOjuJilxO
            U0RpY3Rpb25hcnmiiUAjP84iwRoKapBdUFJFZGl0aW5nTG9va9I6O46PXxAfUFJQb3N0ZXJUaXRsZVN0eWxlQ29uZmlndXJh
            dGlvbqKQQF8QH1BSUG9zdGVyVGl0bGVTdHlsZUNvbmZpZ3VyYXRpb24ACAARABoAJAApADIANwBJAEwAUQBTAHEAdwCcAKsA
            0ADtAQEBCQEnAUQBWwFvAXoBkAGqAcEByAHSAeYB/gH/AgACAgIEAgYCBwIJAgoCDAIOAhACEgIUAhYCGAIaAhwCJQI6AkcC
            TgJQAlECUwJVAnACeQJ+AokCkgK4ArwC4gMCAwsDDQRxBH4EjQSXBKIErASyBLQEtgS4BLoEuwS9BNQE2QThBlIGVAZZBmcG
            awZ5BoAGjQalBq0GtQa9BsoGzAbRBtYG3AbeBuAG5wbzBvsG/gcABwgHCgcPBx0HIAcuBzUHPQdIB0oHTAdOB1AHUgdqB3UH
            mAe0B7YHuAe5B7sHvQfGB88H0QfWB/oH/QghCCYIMwg2CD8ITQhSCHQIdwAAAAAAAAIBAAAAAAAAAJEAAAAAAAAAAAAAAAAA
            AAiZ
            """),
    ]
