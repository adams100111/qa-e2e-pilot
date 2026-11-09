from django.urls import include, path, re_path
from home import views

urlpatterns = [
    path('', views.index, name='home'),
    path('admin/', admin.site.urls),
    path('blog/', include('blog.urls')),
    path("api/", include("api.urls")),
    re_path(r'^legacy/(?P<year>[0-9]{4})/$', views.legacy),
    path('vendor/', include('thirdparty.urls')),
]
