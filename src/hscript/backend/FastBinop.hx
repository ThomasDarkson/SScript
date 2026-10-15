package hscript.backend;

#if cpp
@:cppFileCode("#include <cmath>")
#end
class FastBinop {
	#if cpp
	@:functionCode('
		int t1 = a.mPtr ? a.mPtr->__GetType() : vtNull;
		int t2 = b.mPtr ? b.mPtr->__GetType() : vtNull;
		if ((t1 == vtInt || t1 == vtFloat) && (t2 == vtInt || t2 == vtFloat)) {
			if (t1 == vtInt && t2 == vtInt) {
				::cpp::Int64 wide = (::cpp::Int64)a.mPtr->__ToInt() + (::cpp::Int64)b.mPtr->__ToInt();
				if (wide >= -2147483648LL && wide <= 2147483647LL)
					return Dynamic((int)wide);
				return Dynamic((double)wide);
			}
			return Dynamic(a.mPtr->__ToDouble() + b.mPtr->__ToDouble());
		}
		return a + b;
	')
	public static function add(a:Dynamic, b:Dynamic):Dynamic {
		return a + b;
	}

	@:functionCode('
		if (a.mPtr && b.mPtr && a.mPtr->__GetType() == vtInt && b.mPtr->__GetType() == vtInt) {
			int rhs = b.mPtr->__ToInt();
			if (rhs != 0)
				return Dynamic(a.mPtr->__ToInt() % rhs);
		}
		return a % b;
	')
	public static function mod(a:Dynamic, b:Dynamic):Dynamic {
		return a % b;
	}

	@:functionCode('
		int t = a.mPtr ? a.mPtr->__GetType() : vtNull;
		if (t == vtInt) {
			::cpp::Int64 wide = (::cpp::Int64)a.mPtr->__ToInt() + (::cpp::Int64)delta;
			if (wide >= -2147483648LL && wide <= 2147483647LL)
				return Dynamic((int)wide);
			return Dynamic((double)wide);
		}
		if (t == vtFloat)
			return Dynamic(a.mPtr->__ToDouble() + delta);
		return a + delta;
	')
	public static function addInt(a:Dynamic, delta:Int):Dynamic {
		return a + delta;
	}
	#else
	public static inline function add(a:Dynamic, b:Dynamic):Dynamic return a + b;
	public static inline function mod(a:Dynamic, b:Dynamic):Dynamic return a % b;
	public static inline function addInt(a:Dynamic, delta:Int):Dynamic return a + delta;
	#end

	#if cpp
	@:functionCode('
		if (v.mPtr && v.mPtr->__GetType() == vtFloat) {
			double d = v.mPtr->__ToDouble();
			if (d < -2147483648.0 || d > 2147483647.0 || d != d) {
				if (d != d || d > 1.7e308 || d < -1.7e308)
					return Dynamic((int)0);
				double t = d < 0 ? ::std::ceil(d) : ::std::floor(d);
				t = ::std::fmod(t, 4294967296.0);
				if (t < 0)
					t += 4294967296.0;
				return Dynamic((int)(unsigned int)t);
			}
		}
		return v;
	')
	public static function norm(v:Dynamic):Dynamic {
		return v;
	}
	#else
	public static inline function norm(v:Dynamic):Dynamic return v;
	#end

	public static inline function band(a:Dynamic, b:Dynamic):Dynamic return norm(a) & norm(b);
	public static inline function bor(a:Dynamic, b:Dynamic):Dynamic return norm(a) | norm(b);
	public static inline function bxor(a:Dynamic, b:Dynamic):Dynamic return norm(a) ^ norm(b);
	public static inline function shl(a:Dynamic, b:Dynamic):Dynamic return norm(a) << norm(b);
	public static inline function shr(a:Dynamic, b:Dynamic):Dynamic return norm(a) >> norm(b);
	public static inline function ushr(a:Dynamic, b:Dynamic):Dynamic return norm(a) >>> norm(b);
	public static inline function bnot(a:Dynamic):Dynamic return ~norm(a);
}
