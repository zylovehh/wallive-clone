//
//  WorseQueryShim.m
//  WalliveClone
//
//  纯 C 小包装：把 worse_query 的 ObjC 接口包成 const char* 进出，
//  Swift 侧用 @_silgen_name 声明同名符号就能直接调（本项目不设桥接头，
//  GrappaHelper 也是这么接进来的）。
//

#import "worse_query.h"

/// 对目标路径吃沙箱扩展。成功返回正句柄（持有期间进程可直接读写该路径），
/// 失败返回负数错误码（-1 组不存在、-2 符号解析失败、-3 建查询失败、
/// -4 建符号链接失败、-5 查询被拒、-6 内核拒发扩展、-255 目标不存在）。
__attribute__((visibility("default"), used))
int64_t wq_escape(const char *target, const char *group, bool alt_flags, bool create_dir) {
    if (target == NULL || group == NULL) return -255;
    return worse_query(@(target), @(group), alt_flags, create_dir != 0);
}

/// 用完必须调：释放沙箱扩展句柄。负数句柄直接忽略。
__attribute__((visibility("default"), used))
void wq_release(int64_t handle) {
    worse_query_release(handle);
}
