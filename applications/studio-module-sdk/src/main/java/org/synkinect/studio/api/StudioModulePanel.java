package org.synkinect.studio.api;

import java.util.List;

/** Declarative panel rendered and resized by SynKinect Studio. */
public final class StudioModulePanel {
    public static final int KIND_TEXT = 0;
    public static final int KIND_METRICS = 1;
    public static final int KIND_ACTIONS = 2;
    public static final int KIND_VISUAL = 3;
    public static final int KIND_PROGRESS = 4;
    public static final int KIND_TABLE = 5;
    public static final int KIND_FORM = 6;
    public static final int KIND_LOG = 7;
    public static final int KIND_SPACER = 8;

    private final int kind;
    private final String title;
    private final String text;
    private final List<StudioModuleMetric> metrics;
    private final List<StudioModuleAction> actions;
    private final Visual visual;
    private final Progress progress;
    private final Table table;
    private final List<Field> fields;
    private final List<LogLine> logLines;
    private final int preferredHeight;

    private StudioModulePanel(int kind, String title, String text, List<StudioModuleMetric> metrics, List<StudioModuleAction> actions) {
        this(kind, title, text, metrics, actions, null, null, null, List.of(), List.of(), 0);
    }
    private StudioModulePanel(int kind, String title, String text, List<StudioModuleMetric> metrics, List<StudioModuleAction> actions, Visual visual) {
        this(kind,title,text,metrics,actions,visual,null,null,List.of(),List.of(),0);
    }
    private StudioModulePanel(int kind,String title,String text,List<StudioModuleMetric> metrics,List<StudioModuleAction> actions,
                              Visual visual,Progress progress,Table table,List<Field> fields,List<LogLine> logLines,int preferredHeight) {
        this.kind = kind;
        this.title = title == null ? "" : title;
        this.text = text == null ? "" : text;
        this.metrics = metrics == null ? List.of() : List.copyOf(metrics);
        this.actions = actions == null ? List.of() : List.copyOf(actions);
        this.visual = visual;
        this.progress=progress; this.table=table;
        this.fields=fields==null?List.of():List.copyOf(fields);
        this.logLines=logLines==null?List.of():List.copyOf(logLines);
        this.preferredHeight=Math.max(0,preferredHeight);
    }

    public static StudioModulePanel text(String title, String text) {
        return new StudioModulePanel(KIND_TEXT, title, text, List.of(), List.of());
    }

    public static StudioModulePanel metrics(String title, List<StudioModuleMetric> metrics) {
        return new StudioModulePanel(KIND_METRICS, title, "", metrics, List.of());
    }

    public static StudioModulePanel actions(String title, List<StudioModuleAction> actions) {
        return actions(title, actions, "");
    }

    public static StudioModulePanel actions(String title, List<StudioModuleAction> actions, String status) {
        return new StudioModulePanel(KIND_ACTIONS, title, status, List.of(), actions);
    }

    public static StudioModulePanel visual(String title, Visual visual) {
        return new StudioModulePanel(KIND_VISUAL, title, "", List.of(), List.of(), visual);
    }
    public static StudioModulePanel progress(String title, Progress progress) { return new StudioModulePanel(KIND_PROGRESS,title,"",List.of(),List.of(),null,progress,null,List.of(),List.of(),0); }
    public static StudioModulePanel table(String title, Table table) { return new StudioModulePanel(KIND_TABLE,title,"",List.of(),List.of(),null,null,table,List.of(),List.of(),0); }
    public static StudioModulePanel form(String title,List<Field> fields,List<StudioModuleAction> actions) { return new StudioModulePanel(KIND_FORM,title,"",List.of(),actions,null,null,null,fields,List.of(),0); }
    public static StudioModulePanel log(String title,List<LogLine> lines) { return new StudioModulePanel(KIND_LOG,title,"",List.of(),List.of(),null,null,null,List.of(),lines,0); }
    public static StudioModulePanel spacer(int preferredHeight) { return new StudioModulePanel(KIND_SPACER,"","",List.of(),List.of(),null,null,null,List.of(),List.of(),preferredHeight); }
    public int kind() { return kind; }
    public String title() { return title; }
    public String text() { return text; }
    public List<StudioModuleMetric> metrics() { return metrics; }
    public List<StudioModuleAction> actions() { return actions; }
    public Visual visual() { return visual; }
    public Progress progress() { return progress; }
    public Table table() { return table; }
    public List<Field> fields() { return fields; }
    public List<LogLine> logLines() { return logLines; }
    public int preferredHeight() { return preferredHeight; }
    public static final class Progress {
        private final String label,detail; private final float value; private final boolean indeterminate;
        public Progress(String label,float value,String detail,boolean indeterminate){this.label=label==null?"":label;this.value=Math.max(0f,Math.min(1f,value));this.detail=detail==null?"":detail;this.indeterminate=indeterminate;}
        public String label(){return label;} public float value(){return value;} public String detail(){return detail;} public boolean indeterminate(){return indeterminate;}
    }
    public static final class Table {
        private final List<String> columns; private final List<List<String>> rows;
        public Table(List<String> columns,List<List<String>> rows){this.columns=columns==null?List.of():List.copyOf(columns);if(rows==null){this.rows=List.of();}else{java.util.ArrayList<List<String>> r=new java.util.ArrayList<>();for(List<String> row:rows)r.add(row==null?List.of():List.copyOf(row));this.rows=List.copyOf(r);}}
        public List<String> columns(){return columns;} public List<List<String>> rows(){return rows;}
    }
    public static final class Field {
        public static final int TEXT=0, TOGGLE=1, CHOICE=2, SLIDER=3;
        private final String id,label,value; private final int kind; private final List<String> options; private final double min,max,step;
        public Field(String id,String label,int kind,String value,List<String> options,double min,double max,double step){this.id=id==null?"":id;this.label=label==null?"":label;this.kind=kind;this.value=value==null?"":value;this.options=options==null?List.of():List.copyOf(options);this.min=min;this.max=max;this.step=step;}
        public String id(){return id;} public String label(){return label;} public int kind(){return kind;} public String value(){return value;} public List<String> options(){return options;} public double min(){return min;} public double max(){return max;} public double step(){return step;}
    }
    public static final class LogLine {
        public static final int INFO=0, SUCCESS=1, WARNING=2, ERROR=3;
        private final long timestampMs; private final int level; private final String text;
        public LogLine(long timestampMs,int level,String text){this.timestampMs=timestampMs;this.level=level;this.text=text==null?"":text;}
        public long timestampMs(){return timestampMs;} public int level(){return level;} public String text(){return text;}
    }
    /** Immutable ARGB visualization frame rendered by the Studio host. */
    public static final class Visual {
        public static final int FIT_CONTAIN=0, FIT_COVER=1, FIT_PIXEL=2;
        private final String label; private final int width,height,fit; private final int[] argb;
        public Visual(String label,int width,int height,int[] argb,int fit){
            this.label=label==null?"":label;this.width=Math.max(0,width);this.height=Math.max(0,height);
            int expected=this.width*this.height;this.argb=argb==null||expected==0?new int[0]:java.util.Arrays.copyOf(argb,Math.min(expected,argb.length));
            this.fit=fit<FIT_CONTAIN||fit>FIT_PIXEL?FIT_CONTAIN:fit;
        }
        public String label(){return label;} public int width(){return width;} public int height(){return height;} public int fit(){return fit;}
        public int[] argb(){return java.util.Arrays.copyOf(argb,argb.length);}
        public boolean valid(){return width>0&&height>0&&argb.length==width*height;}
    }
}

