package hscriptBase;

@:keepSub
@:access(hscriptBase.Interp)
class InterpIterator 
{
	public var min:Int;
	public var max:Int;

	public inline function new(instance:Interp, expr1:Expr, expr2:Expr) 
	{
    	var min:Dynamic = instance.expr(expr1);
		var max:Dynamic = instance.expr(expr2);

		var isFloat = Std.isOfType(min, Float);
		var isInt = Std.isOfType(min, Int);

		if (min == null)
			instance.error(ECustom('null should be Int'));
		if (max == null)
			instance.error(ECustom('null should be Int'));

		if (isFloat && !isInt)
			instance.error(ECustom('Float should be Int'));
		if (isFloat && !isInt)
			instance.error(ECustom('Float should be Int'));

		if (!isInt)
			instance.error(ECustom('${Type.getClassName(Type.getClass(min))} should be Int'));
		if (!isInt)
			instance.error(ECustom('${Type.getClassName(Type.getClass(max))} should be Int'));

		this.min = min;
		this.max = max;

		instance = null;
		expr1 = null;
		expr2 = null;
	}

	public inline function hasNext():Bool
	{
		return min < max;
	}

	public inline function next():Int
	{
		return min++;
	}
}