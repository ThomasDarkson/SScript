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

		var isMinFloat = Std.isOfType(min, Float);
		var isMinInt = Std.isOfType(min, Int);
		var isMaxFloat = Std.isOfType(max, Float);
		var isMaxInt = Std.isOfType(max, Int);

		if (min == null)
			instance.error(ECustom('null should be Int'));
		if (max == null)
			instance.error(ECustom('null should be Int'));

		if (isMinFloat && !isMinInt)
			instance.error(ECustom('Float should be Int'));
		if (isMaxFloat && !isMaxInt)
			instance.error(ECustom('Float should be Int'));

		if (!isMinInt)
			instance.error(ECustom('${Type.getClassName(Type.getClass(min))} should be Int'));
		if (!isMaxInt)
			instance.error(ECustom('${Type.getClassName(Type.getClass(max))} should be Int'));

		this.min = cast(min, Int);
		this.max = cast(max, Int);

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