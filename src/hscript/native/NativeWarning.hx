package hscript.native;

class NativeWarning {
    static final logo:String = "            ========            
         ==============         
      ====================      
  ========-........-==========  
========-...:===-...============
========. .==================+++
=======-. .==============+++++++
========...-==========++++++++++
=========.....:---=+++++==+++=++
===========::...  ..-++:..--:.:+
============++*++-.. .=+==+++=++
========++*********:. .+++++++++
=====++************:. .***++++++
==+***************+.. -******+++
********:..-++*+-..  =**********
  ******+:........:=**********  
      ********************      
         **************         
            ********            ";
    public static macro function greet() {
        var sscriptVersion:String = "25.0.0";
        var oldVersion:String = null;

        Sys.println(logo);
        Sys.println("   https://thomasdarkson.com");
        Sys.println("");
        Sys.println("Thank you for using SScript " + sscriptVersion + "!");
        
        if (oldVersion != null) {
            Sys.println("");
            Sys.println("This project uses SScript " + oldVersion + ", but " + oldVersion + " was replaced on Haxelib with " + sscriptVersion + ".");
            Sys.println("SScript " + sscriptVersion + " is backward compatible with every version, including " + oldVersion + "!");
            Sys.println("The project will compile with no problems and you'll benefit from the new features! Enjoy!");
        }

        return macro null;
    }
}