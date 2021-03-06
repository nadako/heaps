package h3d.mat;
import h3d.mat.Data;

@:allow(h3d)
class Texture {

	static var UID = 0;

	/**
		The default texture color format
	**/
	public static var nativeFormat(default,never) : TextureFormat =
		#if flash
			BGRA
		#else
			RGBA // OpenGL, WebGL
		#end;

	/**
		Tells if the Driver requires y-flipping the texture pixels before uploading.
	**/
	public static inline var nativeFlip = 	#if (hlsdl||usegl) true
											#elseif (openfl) false
											#elseif (lime && (cpp || neko || nodejs)) true
											#else false #end;

	var t : h3d.impl.Driver.Texture;
	var mem : h3d.impl.MemoryManager;
	#if debug
	var allocPos : h3d.impl.AllocPos;
	#end
	public var id(default, null) : Int;
	public var name(default, null) : String;
	public var width(default, null) : Int;
	public var height(default, null) : Int;
	public var flags(default, null) : haxe.EnumFlags<TextureFlags>;
	public var format(default, null) : TextureFormat;

	var lastFrame : Int;
	var bits : Int;
	var waitLoads : Array<Void -> Void>;
	public var mipMap(default,set) : MipMap;
	public var filter(default,set) : Filter;
	public var wrap(default, set) : Wrap;

	/**
		If this callback is set, the texture can be re-allocated when the 3D context has been lost or when
		it's been free because of lack of memory.
	**/
	public var realloc : Void -> Void;

	/**
		When the texture is used as render target, tells which depth buffer will be used.
		If set to null, depth testing is disabled.
	**/
	public var depthBuffer : DepthBuffer;

	public function new(w, h, ?flags : Array<TextureFlags>, ?format : TextureFormat, ?allocPos : h3d.impl.AllocPos ) {
		#if !noEngine
		var engine = h3d.Engine.getCurrent();
		this.mem = engine.mem;
		#end
		if( format == null ) format = nativeFormat;
		this.id = ++UID;
		this.format = format;
		this.flags = new haxe.EnumFlags();
		if( flags != null )
			for( f in flags )
				this.flags.set(f);

		var tw = 1, th = 1;
		while( tw < w ) tw <<= 1;
		while( th < h) th <<= 1;
		if( tw != w || th != h )
			this.flags.set(IsNPOT);

		// make the texture disposable if we're out of memory
		// this can be disabled after allocation by reseting realloc
		if( this.flags.has(Target) ) realloc = function() { };

		this.width = w;
		this.height = h;
		this.mipMap = this.flags.has(MipMapped) ? Nearest : None;
		this.filter = Linear;
		this.wrap = Clamp;
		bits &= 0x7FFF;
		#if debug
		this.allocPos = allocPos;
		#end
		if( !this.flags.has(NoAlloc) ) alloc();
	}

	public function alloc() {
		if( t == null )
			mem.allocTexture(this);
	}

	public function clone( ?allocPos : h3d.impl.AllocPos ) {
		var old = lastFrame;
		preventAutoDispose();
		var t = new Texture(width, height, null, format, allocPos);
		h3d.pass.Copy.run(this, t);
		lastFrame = old;
		return t;
	}

	/**
		In case of out of GPU memory, textures that hasn't been used for a long time will be disposed.
		Calling this will make this texture not considered for auto disposal.
	**/
	public function preventAutoDispose() {
		lastFrame = 0x7FFFFFFF;
	}

	/**
		Some textures might take some time to load. You can check flags.has(Loading)
		or add a waitLoad callback which will get called either immediately if the texture is already loaded
		or when loading is complete.
	**/
	public function waitLoad( f : Void -> Void ) {
		if( !flags.has(Loading) ) {
			f();
			return;
		}
		if( waitLoads == null ) waitLoads = [];
		waitLoads.push(f);
	}

	function toString() {
		var str = name;
		if( name == null ) {
			str = "Texture_" + id;
			#if debug
			if( allocPos != null ) str += "(" + allocPos.className+":" + allocPos.lineNumber + ")";
			#end
		}
		return str+"("+width+"x"+height+")";
	}

	public function setName(n) {
		name = n;
	}

	function set_mipMap(m:MipMap) {
		bits = (bits & ~(3 << 0)) | (Type.enumIndex(m) << 0);
		return mipMap = m;
	}

	function set_filter(f:Filter) {
		bits = (bits & ~(3 << 3)) | (Type.enumIndex(f) << 3);
		return filter = f;
	}

	function set_wrap(w:Wrap) {
		bits = (bits & ~(3 << 6)) | (Type.enumIndex(w) << 6);
		return wrap = w;
	}

	public inline function isDisposed() {
		return t == null && realloc == null;
	}

	public function resize(width, height) {
		dispose();

		var tw = 1, th = 1;
		while( tw < width ) tw <<= 1;
		while( th < height ) th <<= 1;
		if( tw != width || th != height )
			this.flags.set(IsNPOT);
		else
			this.flags.unset(IsNPOT);

		this.width = width;
		this.height = height;

		if( !flags.has(NoAlloc) )
			alloc();
	}

	public function clear( color : Int, alpha = 1. ) {
		alloc();
		var p = hxd.Pixels.alloc(width, height, nativeFormat);
		var k = 0;
		var b = color & 0xFF, g = (color >> 8) & 0xFF, r = (color >> 16) & 0xFF, a = Std.int(alpha * 255);
		if( a < 0 ) a = 0 else if( a > 255 ) a = 255;
		switch( nativeFormat ) {
		case RGBA:
		case BGRA:
			// flip b/r
			var tmp = r;
			r = b;
			b = tmp;
		default:
			throw "TODO";
		}
		for( i in 0...width * height ) {
			p.bytes.set(k++,r);
			p.bytes.set(k++,g);
			p.bytes.set(k++,b);
			p.bytes.set(k++,a);
		}
		if( nativeFlip ) p.flags.set(FlipY);
		for( i in 0...(flags.has(Cube) ? 6 : 1) )
			uploadPixels(p, 0, i);
		p.dispose();
	}

	inline function checkSize(width, height, mip) {
		if( width != this.width >> mip || height != this.height >> mip )
			throw "Invalid upload size : " + width + "x" + height + " should be " + (this.width >> mip) + "x" + (this.height >> mip);
	}

	function checkMipMapGen(mipLevel,side) {
		if( mipLevel == 0 && flags.has(MipMapped) && !flags.has(ManualMipMapGen) && (!flags.has(Cube) || side == 5) )
			mem.driver.generateMipMaps(this);
	}

	public function uploadBitmap( bmp : hxd.BitmapData, mipLevel = 0, side = 0 ) {
		alloc();
		checkSize(bmp.width, bmp.height, mipLevel);
		mem.driver.uploadTextureBitmap(this, bmp, mipLevel, side);
		flags.set(WasCleared);
		checkMipMapGen(mipLevel, side);
	}

	public function uploadPixels( pixels : hxd.Pixels, mipLevel = 0, side = 0 ) {
		alloc();
		checkSize(pixels.width, pixels.height, mipLevel);
		mem.driver.uploadTexturePixels(this, pixels, mipLevel, side);
		flags.set(WasCleared);
		checkMipMapGen(mipLevel, side);
	}

	public function dispose() {
		if( t != null ) {
			mem.deleteTexture(this);
			#if debug
			this.allocPos.customParams = ["#DISPOSED"];
			#end
		}
	}

	/**
		Swap two textures, this is an immediate operation.
		BEWARE : if the texture is a cached image (hxd.res.Image), the swap will affect the cache!
	**/
	public function swapTexture( t : Texture ) {
		if( isDisposed() || t.isDisposed() )
			throw "One of the two texture is disposed";
		var tmp = this.t;
		this.t = t.t;
		t.t = tmp;
	}

	/**
		Downloads the current texture data from the GPU.
		Beware, this is a very slow operation that shouldn't be done during rendering.
	**/
	public function capturePixels( face = 0, mipLevel = 0 ) : hxd.Pixels {
		#if flash
		if( flags.has(Cube) ) throw "Can't capture cube texture on this platform";
		if( face != 0 || mipLevel != 0 ) throw "Can't capture face/mipLevel on this platform";
		return capturePixelsFlash();
		#else
		var old = lastFrame;
		preventAutoDispose();
		var pix = mem.driver.capturePixels(this, face, mipLevel);
		lastFrame = old;
		return pix;
		#end
	}

	#if flash
	function capturePixelsFlash() {
		var e = h3d.Engine.getCurrent();
		var oldW = e.width, oldH = e.height;
		var oldF = filter, oldM = mipMap, oldWrap = wrap;
		if( e.width < width || e.height < height )
			e.resize(width, height);
		e.driver.clear(new h3d.Vector(0, 0, 0, 0),1,0);
		var s2d = new h2d.Scene();
		var b = new h2d.Bitmap(h2d.Tile.fromTexture(this), s2d);
		var shader = new h3d.shader.AlphaChannel();
		b.addShader(shader); // erase alpha
		b.blendMode = None;

		mipMap = None;

		s2d.render(e);

		var pixels = hxd.Pixels.alloc(width, height, ARGB);
		e.driver.captureRenderBuffer(pixels);

		shader.showAlpha = true;
		s2d.render(e); // render only alpha channel
		var alpha = hxd.Pixels.alloc(width, height, ARGB);
		e.driver.captureRenderBuffer(alpha);
		var alphaPos = hxd.Pixels.getChannelOffset(alpha.format, A);
		var redPos = hxd.Pixels.getChannelOffset(alpha.format, R);
		var bpp = hxd.Pixels.bytesPerPixel(alpha.format);
		for( y in 0...height ) {
			var p = y * width * bpp;
			for( x in 0...width ) {
				pixels.bytes.set(p + alphaPos, alpha.bytes.get(p + redPos)); // copy alpha value only
				p += bpp;
			}
		}
		alpha.dispose();
		pixels.flags.unset(AlphaPremultiplied);

		if( e.width != oldW || e.height != oldH )
			e.resize(oldW, oldH);
		e.driver.clear(new h3d.Vector(0, 0, 0, 0));
		s2d.dispose();

		filter = oldF;
		mipMap = oldM;
		wrap = oldWrap;
		return pixels;
	}
	#end

	public static function fromBitmap( bmp : hxd.BitmapData, ?allocPos : h3d.impl.AllocPos ) {
		var t = new Texture(bmp.width, bmp.height, allocPos);
		t.uploadBitmap(bmp);
		return t;
	}

	public static function fromPixels( pixels : hxd.Pixels, ?allocPos : h3d.impl.AllocPos ) {
		var t = new Texture(pixels.width, pixels.height, allocPos);
		t.uploadPixels(pixels);
		return t;
	}

	/**
		Creates a 1x1 texture using the RGB color passed as parameter.
	**/
	public static function fromColor( color : Int, ?alpha = 1., ?allocPos : h3d.impl.AllocPos ) {
		var engine = h3d.Engine.getCurrent();
		var aval = Std.int(alpha * 255);
		if( aval < 0 ) aval = 0 else if( aval > 255 ) aval = 255;
		var key = (color&0xFFFFFF) | (aval << 24);
		var t = @:privateAccess engine.textureColorCache.get(key);
		if( t != null )
			return t;
		var t = new Texture(1, 1, null, allocPos);
		t.clear(color, alpha);
		t.realloc = function() t.clear(color, alpha);
		@:privateAccess engine.textureColorCache.set(key, t);
		return t;
	}

	/**
		Returns a default dummy 1x1 black cube texture
	**/
	public static function defaultCubeTexture() {
		var engine = h3d.Engine.getCurrent();
		var t : h3d.mat.Texture = @:privateAccess engine.resCache.get(Texture);
		if( t != null )
			return t;
		t = new Texture(1, 1, [Cube]);
		t.clear(0x202020);
		t.realloc = function() t.clear(0x202020);
		@:privateAccess engine.resCache.set(Texture,t);
		return t;
	}

	static var noiseTextures = new Map<Int,h3d.mat.Texture>();

	public static function genNoise(size) {
		var t = noiseTextures.get(size);
		if( t != null && !t.isDisposed() )
			return t;
		var t = new h3d.mat.Texture(size, size, [NoAlloc]);
		t.realloc = allocNoise.bind(t,size);
		noiseTextures.set(size, t);
		return t;
	}

	static function allocNoise( t : h3d.mat.Texture, size : Int ) {
		var b = new hxd.BitmapData(size, size);
		for( x in 0...size )
			for( y in 0...size ) {
				var n = Std.random(256);
				b.setPixel(x, y, 0xFF000000 | n | (n << 8) | (n << 16));
			}
		t.uploadBitmap(b);
		b.dispose();
	}

}