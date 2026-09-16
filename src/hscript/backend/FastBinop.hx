package hscript.backend;

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
}
