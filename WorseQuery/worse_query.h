//
//  worse_query.h
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

int64_t worse_query(NSString *path, NSString *group, bool alt_flags, bool create_dir);
void worse_query_release(int64_t handle);

//
// 本项目扩展（非上游代码）：多组 flags 逐个试 + class 2 备用查询。
// 观察自一款支持到 iOS 27.3 的同类实现（闭源），这里照思路重写：
//  - class 7 先试 3 组 flags（第一组 0x8100000000 是上游没有的）；
//  - 全挂后若 allow_class2 为真，再试 class 2 的 4 组 flags（27.3 兼容的兜底）。
// out_last_code 记最后一次负数错误码；out_last_class/out_last_flag_index
// 记成功（或最后失败）用的查询类别与第几组 flag，用于诊断日志。
int64_t worse_query_escape2(NSString *target, NSString *group, bool create_dir,
                            bool allow_class2, int64_t *out_last_code,
                            int *out_last_class, int *out_last_flag_index);

#endif /* worse_query_h */
