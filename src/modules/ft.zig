// FreeType2 C API bindings using c_import
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const FT_Library = c.FT_Library;
pub const FT_Face = c.FT_Face;
pub const FT_Init_FreeType = c.FT_Init_FreeType;
pub const FT_Done_FreeType = c.FT_Done_FreeType;
pub const FT_New_Face = c.FT_New_Face;
pub const FT_Done_Face = c.FT_Done_Face;
pub const FT_Set_Pixel_Sizes = c.FT_Set_Pixel_Sizes;
pub const FT_Get_Char_Index = c.FT_Get_Char_Index;
pub const FT_Load_Glyph = c.FT_Load_Glyph;
pub const FT_LOAD_RENDER = c.FT_LOAD_RENDER;

// Helper to access nested C structs
pub fn getBitmap(face: FT_Face) *const c.FT_Bitmap {
    return &face.*.glyph.*.bitmap;
}

pub const FT_Bitmap = c.FT_Bitmap;
